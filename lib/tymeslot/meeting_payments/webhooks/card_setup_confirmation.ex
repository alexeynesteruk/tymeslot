defmodule Tymeslot.MeetingPayments.Webhooks.CardSetupConfirmation do
  @moduledoc """
  Shared lock-and-confirm transition for deferred Stripe setup events.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.PostConfirmation
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.Repo

  @spec apply(BookingPaymentSchema.t(), map()) :: :ok | {:error, term()}
  def apply(%BookingPaymentSchema{} = payment, attrs) do
    attrs = resolve_customer(payment, attrs)

    case Repo.transaction(fn -> apply_in_transaction(payment, attrs) end) do
      {:ok, {:confirmed, updated, meeting}} ->
        PostConfirmation.enqueue(meeting, updated)
        broadcast_card_saved(meeting.id)
        :ok

      {:ok, :already_confirmed} ->
        broadcast_card_saved(payment.meeting_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_customer(payment, attrs) do
    cond do
      present?(attrs[:stripe_customer_id]) ->
        attrs

      present?(payment.stripe_customer_id) ->
        Map.put(attrs, :stripe_customer_id, payment.stripe_customer_id)

      present?(attrs[:stripe_payment_method_id]) ->
        case create_and_attach(payment, attrs[:stripe_payment_method_id]) do
          {:ok, customer_id} -> Map.put(attrs, :stripe_customer_id, customer_id)
          {:error, _reason} -> attrs
        end

      true ->
        attrs
    end
  end

  defp create_and_attach(payment, payment_method_id) do
    with {:ok, customer} <-
           StripeAdapter.create_customer(
             customer_params(payment),
             connect_account: payment.stripe_account_id,
             idempotency_key: "setup-customer:#{payment.id}"
           ),
         {:ok, customer_id} <- customer_id(customer),
         {:ok, _method} <-
           StripeAdapter.attach_payment_method(
             payment_method_id,
             %{customer: customer_id},
             connect_account: payment.stripe_account_id
           ) do
      {:ok, customer_id}
    end
  end

  defp customer_params(payment) do
    %{email: payment.attendee_email}
    |> then(fn params ->
      if present?(payment.attendee_name),
        do: Map.put(params, :name, payment.attendee_name),
        else: params
    end)
  end

  defp customer_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp customer_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp customer_id(_other), do: {:error, :customer_missing}

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false

  defp broadcast_card_saved(nil), do: :ok

  defp broadcast_card_saved(meeting_id) do
    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :card_saved)
  end

  defp apply_in_transaction(payment, attrs) do
    with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
         :ok <- verify_identity(locked, attrs),
         already_saved? = saved_status?(locked.status),
         {:ok, updated} <- persist_card_saved(locked, attrs),
         {:ok, meeting} <- confirm_meeting(updated) do
      if already_saved? do
        :already_confirmed
      else
        {:confirmed, updated, meeting}
      end
    else
      :already_confirmed ->
        :already_confirmed

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp saved_status?(status)
       when status in [
              "card_saved",
              "charge_processing",
              "charge_failed",
              "action_required",
              "paid",
              "partially_refunded",
              "refunded",
              "disputed"
            ],
       do: true

  defp saved_status?(_status), do: false

  defp verify_identity(payment, attrs) do
    cond do
      connected_account_mismatch?(payment, attrs) ->
        {:error, :setup_intent_mismatch}

      meeting_mismatch?(payment, attrs) ->
        {:error, :setup_intent_mismatch}

      snapshot_mismatch?(payment, attrs) ->
        {:error, :setup_intent_mismatch}

      bound_setup_intent_mismatch?(payment, attrs) ->
        {:error, :setup_intent_mismatch}

      true ->
        :ok
    end
  end

  defp connected_account_mismatch?(payment, attrs) do
    account_id = attrs[:stripe_account_id]
    is_binary(account_id) and account_id != payment.stripe_account_id
  end

  defp meeting_mismatch?(payment, attrs) do
    meeting_id = attrs[:meeting_id]
    is_binary(meeting_id) and meeting_id != payment.meeting_id
  end

  defp snapshot_mismatch?(payment, attrs) do
    snapshot = payment.service_snapshot
    service_id = attrs[:service_id]
    version = attrs[:service_version]

    (is_binary(service_id) and service_id != snapshot["service_id"]) or
      (not is_nil(version) and to_string(version) != to_string(snapshot["event_type_version"]))
  end

  defp bound_setup_intent_mismatch?(payment, attrs) do
    incoming = attrs[:stripe_setup_intent_id]
    bound = payment.stripe_setup_intent_id
    is_binary(bound) and is_binary(incoming) and bound != incoming
  end

  defp persist_card_saved(%{status: status} = payment, attrs) do
    if saved_status?(status) do
      bind_setup_intent(payment, attrs)
    else
      mark_card_saved(payment, attrs)
    end
  end

  defp bind_setup_intent(payment, attrs) do
    incoming = attrs[:stripe_setup_intent_id]

    updates =
      Map.reject(
        %{
          stripe_setup_intent_id: payment.stripe_setup_intent_id || incoming,
          stripe_customer_id: payment.stripe_customer_id || attrs[:stripe_customer_id],
          stripe_payment_method_id:
            payment.stripe_payment_method_id || attrs[:stripe_payment_method_id],
          last_event_id: attrs[:event_id]
        },
        fn {_key, value} -> is_nil(value) end
      )

    if updates == %{} do
      {:ok, payment}
    else
      BookingPaymentQueries.update(payment, updates)
    end
  end

  defp mark_card_saved(payment, attrs) do
    updates =
      Map.reject(
        %{
          status: "card_saved",
          stripe_setup_intent_id:
            payment.stripe_setup_intent_id || attrs[:stripe_setup_intent_id],
          stripe_customer_id: attrs[:stripe_customer_id],
          stripe_payment_method_id: attrs[:stripe_payment_method_id],
          last_event_id: attrs[:event_id]
        },
        fn {_key, value} -> is_nil(value) end
      )

    case BookingPaymentQueries.update(payment, updates) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_setup_succeeded)

        _audit =
          BookingPaymentAudits.append(%{
            booking_payment_id: updated.id,
            meeting_id: updated.meeting_id,
            actor_type: "stripe",
            action: "card_setup",
            result: "card_saved",
            stripe_object_id: attrs[:stripe_setup_intent_id],
            detail_code: attrs[:event_type] || "setup_succeeded"
          })

        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp confirm_meeting(%{meeting_id: nil}), do: {:error, :meeting_missing}

  defp confirm_meeting(payment) do
    case MeetingQueries.get_meeting(payment.meeting_id) do
      {:ok, %{status: "confirmed"} = meeting} ->
        {:ok, meeting}

      {:ok, %{status: status} = meeting} when status in ["awaiting_card", "expired"] ->
        with {:ok, confirmed} <- MeetingQueries.update_meeting(meeting, %{status: "confirmed"}),
             :ok <- CrmProjection.append_transition(confirmed, "confirmed") do
          {:ok, confirmed}
        end

      {:ok, _other} ->
        :already_confirmed

      {:error, :not_found} ->
        {:error, :meeting_missing}
    end
  end
end
