defmodule Tymeslot.MeetingPayments.Webhooks.SetupIntentSetupFailed do
  @moduledoc """
  Releases a deferred booking slot when Stripe setup fails before a card is saved.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

  @event_type "setup_intent.setup_failed"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case lookup_payment(object) do
      nil ->
        Logger.info("setup_intent.setup_failed: no booking_payment matched",
          setup_intent_id: object["id"]
        )

        {:ok, :ok}

      payment ->
        classify(release(payment, event_id, event["account"]))
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp lookup_payment(%{"id" => setup_intent_id} = object) when is_binary(setup_intent_id) do
    BookingPaymentQueries.by_setup_intent_id(setup_intent_id) || lookup_by_metadata(object)
  end

  defp lookup_payment(object), do: lookup_by_metadata(object)

  defp lookup_by_metadata(%{"metadata" => %{"booking_payment_id" => id}}) when is_binary(id) do
    BookingPaymentQueries.get(id)
  end

  defp lookup_by_metadata(_object), do: nil

  defp release(payment, event_id, account_id) do
    case Repo.transaction(fn -> release_in_transaction(payment, event_id, account_id) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_in_transaction(payment, event_id, account_id) do
    with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
         :ok <- verify_account(locked, account_id),
         :ok <- cancel_if_setup_pending(locked, event_id),
         :ok <- expire_if_awaiting_card(locked.meeting_id) do
      :ok
    else
      :already_final ->
        :ok

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp verify_account(payment, account_id)
       when is_binary(account_id) and account_id != payment.stripe_account_id do
    {:error, :setup_intent_mismatch}
  end

  defp verify_account(_payment, _account_id), do: :ok

  defp cancel_if_setup_pending(%{status: "setup_pending"} = payment, event_id) do
    case BookingPaymentQueries.update(payment, %{status: "cancelled", last_event_id: event_id}) do
      {:ok, updated} ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_setup_failed)

        _audit =
          BookingPaymentAudits.append(%{
            booking_payment_id: updated.id,
            meeting_id: updated.meeting_id,
            actor_type: "stripe",
            action: "card_setup",
            result: "cancelled",
            stripe_object_id: payment.stripe_setup_intent_id,
            detail_code: "setup_failed"
          })

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_if_setup_pending(_payment, _event_id), do: :already_final

  defp expire_if_awaiting_card(nil), do: :ok

  defp expire_if_awaiting_card(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, %{status: "awaiting_card"} = meeting} ->
        case MeetingQueries.update_meeting(meeting, %{status: "expired"}) do
          {:ok, _meeting} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other} ->
        :ok

      {:error, :not_found} ->
        :ok
    end
  end
end
