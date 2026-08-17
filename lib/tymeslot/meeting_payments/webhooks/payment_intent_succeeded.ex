defmodule Tymeslot.MeetingPayments.Webhooks.PaymentIntentSucceeded do
  @moduledoc "Applies monotonic deferred PaymentIntent success events."

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.Repo

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event), do: apply_event(event, :succeeded)

  @doc false
  @spec apply_event(map(), :succeeded | :failed) :: :ok | {:error, term()}
  def apply_event(%{"account" => account, "data" => %{"object" => intent}}, outcome) do
    with payment_id when is_binary(payment_id) <- metadata(intent, "booking_payment_id"),
         %{id: ^payment_id} = payment <- BookingPaymentQueries.get(payment_id) do
      apply_locked(payment, account, intent, outcome)
    else
      _missing -> :ok
    end
  end

  def apply_event(_event, _outcome), do: {:error, :invalid_event}

  defp apply_locked(payment, account, intent, outcome) do
    case Repo.transaction(fn ->
           with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
                :ok <- validate_or_skip(locked, account, intent),
                {:ok, updated} <- update(locked, intent, outcome),
                {:ok, _audit} <- audit(updated, outcome) do
             updated
           else
             :no_op -> :no_op
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_or_skip(%{status: status}, _account, _intent)
       when status != "charge_processing",
       do: :no_op

  defp validate_or_skip(payment, account, intent) do
    attempt = parse_attempt(metadata(intent, "charge_attempt"))
    intent_id = intent["id"]

    cond do
      not (is_binary(intent_id) and String.trim(intent_id) != "") ->
        {:error, :payment_intent_mismatch}

      payment.stripe_account_id != account ->
        {:error, :payment_intent_mismatch}

      payment.charge_attempt != attempt ->
        {:error, :payment_intent_mismatch}

      metadata(intent, "meeting_id") != payment.meeting_id ->
        {:error, :payment_intent_mismatch}

      metadata(intent, "service_id") != payment.service_snapshot["service_id"] ->
        {:error, :payment_intent_mismatch}

      is_binary(payment.stripe_payment_intent_id) and
          payment.stripe_payment_intent_id != intent_id ->
        {:error, :payment_intent_mismatch}

      true ->
        :ok
    end
  end

  defp update(payment, intent, :succeeded) do
    BookingPaymentQueries.update(payment, %{
      status: "paid",
      stripe_payment_intent_id: intent["id"],
      stripe_charge_id: charge_id(intent),
      paid_at: DateTime.utc_now(:second),
      last_error_code: nil
    })
  end

  defp update(payment, intent, :failed) do
    BookingPaymentQueries.update(payment, %{
      status: failed_status(intent),
      stripe_payment_intent_id: intent["id"],
      last_error_code: error_code(intent)
    })
  end

  defp audit(payment, outcome) do
    BookingPaymentAudits.append(%{
      booking_payment_id: payment.id,
      meeting_id: payment.meeting_id,
      actor_type: "stripe",
      action: if(outcome == :succeeded, do: "charge_succeeded", else: failed_action(payment)),
      attempt: payment.charge_attempt,
      amount_cents: payment.service_snapshot["amount_cents"],
      result: payment.status,
      stripe_object_id: payment.stripe_payment_intent_id,
      detail_code: payment.last_error_code
    })
  end

  defp failed_action(%{status: "action_required"}), do: "charge_action_required"
  defp failed_action(_payment), do: "charge_failed"

  defp failed_status(%{"status" => "requires_action"}), do: "action_required"
  defp failed_status(_intent), do: "charge_failed"

  defp error_code(%{"last_payment_error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(%{"status" => "requires_action"}), do: "authentication_required"
  defp error_code(_intent), do: "payment_failed"

  defp charge_id(%{"latest_charge" => %{"id" => id}}) when is_binary(id), do: id
  defp charge_id(%{"latest_charge" => id}) when is_binary(id), do: id
  defp charge_id(_intent), do: nil

  defp metadata(%{"metadata" => metadata}, key) when is_map(metadata), do: metadata[key]
  defp metadata(_intent, _key), do: nil

  defp parse_attempt(value) when is_integer(value), do: value

  defp parse_attempt(value) when is_binary(value) do
    case Integer.parse(value) do
      {attempt, ""} -> attempt
      _invalid -> nil
    end
  end

  defp parse_attempt(_value), do: nil
end
