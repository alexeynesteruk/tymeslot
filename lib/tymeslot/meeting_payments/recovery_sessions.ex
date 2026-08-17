defmodule Tymeslot.MeetingPayments.RecoverySessions do
  @moduledoc "Creates owner-authorized Stripe-hosted recovery checkouts."

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Repo
  alias TymeslotWeb.Endpoint

  @session_expiry_seconds 30 * 60

  @spec create(Ecto.UUID.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def create(payment_id, actor_user_id) when is_integer(actor_user_id) do
    with {:ok, payment} <- load_authorized(payment_id, actor_user_id),
         {:ok, session} <- create_session(payment),
         {:ok, updated} <- attach_session(payment, actor_user_id, session) do
      {:ok, %{checkout_url: session_url(session), booking_payment: updated}}
    end
  end

  def create(_payment_id, _actor_user_id), do: {:error, :not_authorized}

  defp load_authorized(payment_id, actor_user_id) do
    case BookingPaymentQueries.get(payment_id) do
      nil ->
        {:error, :not_found}

      %{host_user_id: host_user_id} when host_user_id != actor_user_id ->
        {:error, :not_authorized}

      %{status: status} = payment when status in ["charge_failed", "action_required"] ->
        {:ok, payment}

      _payment ->
        {:error, :invalid_payment_state}
    end
  end

  defp create_session(payment) do
    snapshot = payment.service_snapshot

    StripeAdapter.create_checkout_session(
      %{
        mode: "payment",
        payment_method_types: ["card"],
        line_items: [
          %{
            price_data: %{
              currency: snapshot["currency"],
              unit_amount: snapshot["amount_cents"],
              product_data: %{name: snapshot["service_name"]}
            },
            quantity: 1
          }
        ],
        payment_intent_data: %{
          metadata: %{
            booking_payment_id: payment.id,
            meeting_id: payment.meeting_id,
            service_id: snapshot["service_id"],
            charge_attempt: payment.charge_attempt,
            payment_purpose: "recovery"
          }
        },
        customer_email: payment.attendee_email,
        client_reference_id: payment.meeting_id,
        success_url: Endpoint.url() <> "/dashboard/payments?recovery=success",
        cancel_url: Endpoint.url() <> "/dashboard/payments?recovery=cancelled",
        metadata: %{
          booking_payment_id: payment.id,
          meeting_id: payment.meeting_id,
          service_id: snapshot["service_id"],
          charge_attempt: payment.charge_attempt,
          payment_purpose: "recovery"
        },
        expires_at: System.os_time(:second) + @session_expiry_seconds
      },
      connect_account: payment.stripe_account_id,
      idempotency_key: "recovery:#{payment.id}:#{payment.charge_attempt}"
    )
  end

  defp attach_session(payment, actor_user_id, session) do
    session_id = field(session, :id)

    Repo.transaction(fn ->
      with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
           :ok <- require_same_attempt(locked, payment),
           {:ok, updated} <-
             BookingPaymentQueries.update(locked, %{stripe_recovery_session_id: session_id}),
           {:ok, _audit} <- audit(updated, actor_user_id, session_id) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp require_same_attempt(%{status: status, charge_attempt: attempt}, %{charge_attempt: attempt})
       when status in ["charge_failed", "action_required"],
       do: :ok

  defp require_same_attempt(_locked, _payment), do: {:error, :invalid_payment_state}

  defp audit(payment, actor_user_id, session_id) do
    BookingPaymentAudits.append(%{
      booking_payment_id: payment.id,
      meeting_id: payment.meeting_id,
      actor_type: "owner",
      actor_user_id: actor_user_id,
      action: "recovery_created",
      attempt: payment.charge_attempt,
      amount_cents: payment.service_snapshot["amount_cents"],
      result: "created",
      stripe_object_id: session_id
    })
  end

  defp session_url(session), do: field(session, :url)
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
