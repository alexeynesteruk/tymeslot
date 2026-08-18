defmodule Tymeslot.MeetingPayments.CardSetups do
  @moduledoc """
  Creates a Stripe Checkout Session in setup mode for deferred payments.

  The card is saved and the booking is confirmed later by webhooks. This
  module never creates a PaymentIntent, capture, or charge.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Features

  alias Tymeslot.MeetingPayments.{
    BookingPaymentQueries,
    ConnectAccountQueries,
    PaymentTiming,
    StripeAdapter
  }

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Themes.Catalog, as: ThemeCatalog
  alias TymeslotWeb.Endpoint

  @session_expiry_seconds 30 * 60

  @type create_result :: %{
          checkout_url: String.t(),
          booking_payment: Tymeslot.MeetingPayments.BookingPaymentSchema.t()
        }

  @spec create_session_for_booking(Tymeslot.Meetings.MeetingSchema.t()) ::
          {:ok, create_result()} | {:error, term()}
  def create_session_for_booking(meeting) do
    with {:ok, context} <- build_context(meeting),
         {:ok, booking_payment} <- BookingPaymentQueries.insert(context.snapshot),
         {:ok, booking_payment} <- attach_customer(meeting, booking_payment, context),
         {:ok, session} <- create_setup_session(meeting, context, booking_payment),
         {:ok, booking_payment} <- attach_setup_details(booking_payment, session, context) do
      {:ok, %{checkout_url: session_url(session), booking_payment: booking_payment}}
    end
  end

  defp build_context(meeting) do
    with {:ok, host} <- fetch_host(meeting.organizer_user_id),
         :ok <- check_payments_access(host.id),
         {:ok, account} <- fetch_connect_account(host.id),
         {:ok, meeting_type} <- fetch_meeting_type(meeting.meeting_type_id),
         {:ok, snapshot} <- deferred_snapshot(meeting, host, account, meeting_type) do
      theme_id = resolve_theme_id(host.id)

      {:ok,
       %{
         host: host,
         account: account,
         meeting_type: meeting_type,
         theme_id: theme_id,
         theme_slug: theme_slug_for(theme_id),
         snapshot: Map.put(snapshot, :booking_theme_id, theme_id)
       }}
    end
  end

  defp deferred_snapshot(meeting, host, account, meeting_type) do
    service_snapshot = meeting.service_snapshot || %{}

    attrs = %{
      meeting_id: meeting.id,
      stripe_account_id: account.stripe_account_id,
      host_user_id: host.id,
      host_email: host.email,
      host_name: host.name,
      attendee_email: meeting.attendee_email,
      attendee_name: meeting.attendee_name,
      meeting_type_name: meeting_type.name,
      service_snapshot: service_snapshot,
      amount_cents: service_snapshot["amount_cents"],
      currency: service_snapshot["currency"],
      application_fee_cents: 0,
      payment_timing: "deferred",
      status: "setup_pending"
    }

    case PaymentTiming.validate_deferred(attrs) do
      {:ok, "deferred"} -> {:ok, attrs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_setup_session(meeting, context, booking_payment) do
    %{account: account, theme_slug: slug} = context
    snapshot = booking_payment.service_snapshot

    StripeAdapter.create_setup_checkout_session(
      %{
        mode: "setup",
        payment_method_types: ["card"],
        customer: booking_payment.stripe_customer_id,
        success_url: success_url(slug, meeting.id) <> "?session_id={CHECKOUT_SESSION_ID}",
        cancel_url: cancel_url(slug, meeting.id),
        client_reference_id: meeting.id,
        expires_at: System.os_time(:second) + @session_expiry_seconds,
        locale: stripe_locale(meeting.attendee_locale),
        setup_intent_data: %{
          metadata: %{
            meeting_id: meeting.id,
            booking_payment_id: booking_payment.id,
            service_id: snapshot["service_id"],
            service_version: snapshot["event_type_version"]
          }
        }
      },
      connect_account: account.stripe_account_id,
      idempotency_key: "setup-checkout:#{booking_payment.id}"
    )
  end

  defp attach_customer(meeting, booking_payment, context) do
    with {:ok, customer} <-
           StripeAdapter.create_customer(
             customer_params(meeting),
             connect_account: context.account.stripe_account_id,
             idempotency_key: "setup-customer:#{booking_payment.id}"
           ),
         {:ok, customer_id} <- customer_id(customer) do
      persist_customer(booking_payment, customer_id)
    end
  end

  defp customer_params(meeting) do
    %{email: meeting.attendee_email}
    |> maybe_put(:name, meeting.attendee_name)
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp customer_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp customer_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp customer_id(_other), do: {:error, :customer_missing}

  defp persist_customer(booking_payment, customer_id) do
    Repo.transaction(fn ->
      case BookingPaymentQueries.get_for_update(booking_payment.id) do
        {:ok, locked} ->
          case BookingPaymentQueries.update(locked, %{stripe_customer_id: customer_id}) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp attach_setup_details(booking_payment, session, context) do
    with {:ok, setup_intent_id} <- setup_intent_id(session, context, session_id(session)) do
      attrs =
        Map.reject(
          %{
            stripe_checkout_session_id: session_id(session),
            stripe_setup_intent_id: setup_intent_id
          },
          fn {_key, value} -> is_nil(value) end
        )

      Repo.transaction(fn ->
        case BookingPaymentQueries.get_for_update(booking_payment.id) do
          {:ok, locked} ->
            case BookingPaymentQueries.update(locked, attrs) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  defp setup_intent_id(session, context, session_id) do
    case setup_intent_value(session) do
      id when is_binary(id) ->
        expand_setup_intent(session_id, id, context)

      %{id: id} when is_binary(id) ->
        {:ok, id}

      %{"id" => id} when is_binary(id) ->
        {:ok, id}

      _missing ->
        expand_setup_intent(session_id, nil, context)
    end
  end

  defp expand_setup_intent(session_id, expected_id, context) do
    case StripeAdapter.retrieve_checkout_session(session_id,
           connect_account: context.account.stripe_account_id,
           expand: ["setup_intent"]
         ) do
      {:ok, expanded} ->
        if session_id(expanded) in [session_id, nil] do
          {:ok, extract_setup_intent_id(expanded) || expected_id}
        else
          {:error, :setup_session_mismatch}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp setup_intent_value(session) when is_map(session) do
    Map.get(session, :setup_intent) || Map.get(session, "setup_intent")
  end

  defp extract_setup_intent_id(session) when is_map(session) do
    case setup_intent_value(session) do
      id when is_binary(id) -> id
      %{id: id} when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      _other -> nil
    end
  end

  defp session_id(session) when is_map(session) do
    Map.get(session, :id) || Map.get(session, "id")
  end

  defp session_url(session) when is_map(session) do
    Map.get(session, :url) || Map.get(session, "url")
  end

  defp check_payments_access(host_user_id) do
    case Features.check_access(host_user_id, :meeting_payments) do
      :ok -> :ok
      {:error, _reason} -> {:error, :payments_unavailable}
    end
  end

  defp fetch_host(nil), do: {:error, :host_missing}

  defp fetch_host(user_id) do
    case UserQueries.get_user(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :host_not_found}
    end
  end

  defp fetch_connect_account(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{charges_enabled: true} = account -> {:ok, account}
      _account_or_nil -> {:error, :payments_unavailable}
    end
  end

  defp fetch_meeting_type(nil), do: {:error, :meeting_type_missing}

  defp fetch_meeting_type(id) do
    {:ok, MeetingTypeQueries.get_meeting_type!(id)}
  rescue
    Ecto.NoResultsError ->
      Logger.warning("Setup session requested for a missing meeting type", meeting_type_id: id)
      {:error, :meeting_type_not_found}
  end

  defp resolve_theme_id(user_id) do
    case Profiles.get_profile(user_id) do
      %{booking_theme: theme_id} when is_binary(theme_id) -> theme_id
      _missing_or_default -> ThemeCatalog.default_id()
    end
  end

  defp theme_slug_for(theme_id) do
    case ThemeCatalog.id_to_key(theme_id) do
      {:ok, key} -> Atom.to_string(key)
      {:error, :invalid_theme_id} -> Atom.to_string(ThemeCatalog.default_key())
    end
  end

  defp success_url(theme_slug, meeting_id) do
    "#{Endpoint.url()}/themes/#{theme_slug}/payment-processing/#{meeting_id}"
  end

  defp cancel_url(theme_slug, meeting_id) do
    "#{Endpoint.url()}/themes/#{theme_slug}/payment-cancelled/#{meeting_id}"
  end

  defp stripe_locale(nil), do: "auto"
  defp stripe_locale("en"), do: "en"
  defp stripe_locale("de"), do: "de"
  defp stripe_locale("fr"), do: "fr"
  defp stripe_locale("it"), do: "it"
  defp stripe_locale("cs"), do: "cs"
  defp stripe_locale(_other), do: "auto"
end
