defmodule Tymeslot.MeetingPayments.Workers.ChargeBookingPayment do
  @moduledoc "Executes one reserved deferred charge without automatic retries."

  use Oban.Worker, queue: :payments, max_attempts: 1

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"booking_payment_id" => payment_id, "charge_attempt" => attempt}
      }) do
    with {:ok, payment} <- load_reserved(payment_id, attempt) do
      payment
      |> charge_params(attempt)
      |> StripeAdapter.create_payment_intent(
        connect_account: payment.stripe_account_id,
        idempotency_key: "booking-charge:#{payment.id}:#{attempt}"
      )
      |> apply_result(payment.id, attempt)
    else
      :stale -> :ok
    end
  end

  defp load_reserved(payment_id, attempt) do
    case BookingPaymentQueries.get(payment_id) do
      %{status: "charge_processing", charge_attempt: ^attempt} = payment -> {:ok, payment}
      _payment -> :stale
    end
  end

  defp charge_params(payment, attempt) do
    %{
      amount: payment.service_snapshot["amount_cents"],
      currency: payment.service_snapshot["currency"],
      customer: payment.stripe_customer_id,
      payment_method: payment.stripe_payment_method_id,
      off_session: true,
      confirm: true,
      receipt_email: payment.attendee_email,
      metadata: %{
        meeting_id: payment.meeting_id,
        booking_payment_id: payment.id,
        service_id: payment.service_snapshot["service_id"],
        charge_attempt: attempt
      }
    }
  end

  defp apply_result(result, payment_id, attempt) do
    Repo.transaction(fn ->
      with {:ok, payment} <- BookingPaymentQueries.get_for_update(payment_id),
           :ok <- require_active_attempt(payment, attempt),
           {:ok, updated} <- update_for_result(payment, result),
           {:ok, _audit} <- audit(updated, result) do
        updated
      else
        :stale -> :stale
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    :ok
  end

  defp require_active_attempt(%{status: "charge_processing", charge_attempt: attempt}, attempt),
    do: :ok

  defp require_active_attempt(_payment, _attempt), do: :stale

  defp update_for_result(payment, {:ok, %{"id" => intent_id, "status" => "succeeded"} = intent}) do
    BookingPaymentQueries.update(payment, %{
      status: "paid",
      stripe_payment_intent_id: intent_id,
      stripe_charge_id: charge_id(intent),
      paid_at: DateTime.utc_now(:second),
      last_error_code: nil
    })
  end

  defp update_for_result(
         payment,
         {:ok, %{"id" => intent_id, "status" => "requires_action"} = intent}
       ) do
    BookingPaymentQueries.update(payment, %{
      status: "action_required",
      stripe_payment_intent_id: intent_id,
      last_error_code: error_code(intent, "authentication_required")
    })
  end

  defp update_for_result(
         payment,
         {:ok, %{"id" => intent_id, "status" => "requires_payment_method"} = intent}
       ) do
    BookingPaymentQueries.update(payment, %{
      status: "charge_failed",
      stripe_payment_intent_id: intent_id,
      last_error_code: error_code(intent, "payment_failed")
    })
  end

  defp update_for_result(payment, _result) do
    BookingPaymentQueries.update(payment, %{last_error_code: "uncertain_result"})
  end

  defp audit(payment, result) do
    {action, audit_result, stripe_object_id, detail_code} = audit_values(payment, result)

    BookingPaymentAudits.append(%{
      booking_payment_id: payment.id,
      meeting_id: payment.meeting_id,
      actor_type: "system",
      action: action,
      attempt: payment.charge_attempt,
      amount_cents: payment.service_snapshot["amount_cents"],
      result: audit_result,
      stripe_object_id: stripe_object_id,
      detail_code: detail_code
    })
  end

  defp audit_values(_payment, {:ok, %{"id" => id, "status" => "succeeded"}}),
    do: {"charge_succeeded", "paid", id, nil}

  defp audit_values(payment, {:ok, %{"id" => id, "status" => "requires_action"}}),
    do: {"charge_action_required", "action_required", id, payment.last_error_code}

  defp audit_values(payment, {:ok, %{"id" => id, "status" => "requires_payment_method"}}),
    do: {"charge_failed", "failed", id, payment.last_error_code}

  defp audit_values(payment, _result),
    do: {"charge_uncertain", "processing", payment.stripe_payment_intent_id, "uncertain_result"}

  defp charge_id(%{"latest_charge" => %{"id" => id}}) when is_binary(id), do: id
  defp charge_id(%{"latest_charge" => id}) when is_binary(id), do: id
  defp charge_id(_intent), do: nil

  defp error_code(%{"last_payment_error" => %{"code" => code}}, _fallback)
       when is_binary(code),
       do: code

  defp error_code(_intent, fallback), do: fallback
end
