defmodule Tymeslot.MeetingPayments.Webhooks.CardSetupConfirmation do
  @moduledoc """
  Shared lock-and-confirm transition for deferred Stripe setup events.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.PostConfirmation
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.Repo

  @spec apply(BookingPaymentSchema.t(), map()) :: :ok | {:error, term()}
  def apply(%BookingPaymentSchema{} = payment, attrs) do
    case Repo.transaction(fn -> apply_in_transaction(payment, attrs) end) do
      {:ok, {:confirmed, updated, meeting}} ->
        PostConfirmation.enqueue(meeting, updated)
        :ok

      {:ok, :already_confirmed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
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
    snapshot = payment.service_snapshot || %{}
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
