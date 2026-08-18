defmodule Tymeslot.MeetingPayments.ManualCharges do
  @moduledoc "Atomically reserves owner-authorized deferred charges."

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo

  @worker "Elixir.Tymeslot.MeetingPayments.Workers.ChargeBookingPayment"

  @spec reserve(Ecto.UUID.t(), pos_integer()) :: {:ok, map()} | {:error, atom() | term()}
  def reserve(payment_id, actor_user_id) when is_integer(actor_user_id) do
    with {:ok, payment} <- fetch_payment(payment_id),
         :ok <- authorize(payment, actor_user_id),
         :ok <- heal_missing_customer(payment) do
      do_reserve(payment_id, actor_user_id)
    end
  end

  def reserve(_payment_id, _actor_user_id), do: {:error, :not_authorized}

  defp do_reserve(payment_id, actor_user_id) do
    Repo.transaction(fn ->
      with {:ok, payment} <- BookingPaymentQueries.get_for_update(payment_id),
           :ok <- authorize(payment, actor_user_id),
           {:ok, meeting} <- MeetingQueries.get_meeting_for_update(payment.meeting_id),
           :ok <- require_completed(meeting),
           :ok <- require_deferred(payment),
           :ok <- require_card_saved(payment),
           {:ok, amount_cents, currency} <- validate_snapshot(payment, meeting),
           :ok <- require_identifier(payment.stripe_account_id, :missing_stripe_account),
           :ok <- require_identifier(payment.stripe_customer_id, :missing_stripe_customer),
           :ok <-
             require_identifier(payment.stripe_payment_method_id, :missing_stripe_payment_method),
           {:ok, reserved} <- reserve_payment(payment),
           {:ok, _audit} <- audit(reserved, actor_user_id, amount_cents),
           {:ok, _job} <- enqueue(reserved) do
        %{
          amount_cents: amount_cents,
          currency: currency,
          charge_attempt: reserved.charge_attempt,
          booking_payment: reserved
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp fetch_payment(payment_id) do
    case BookingPaymentQueries.get(payment_id) do
      nil -> {:error, :not_found}
      payment -> {:ok, payment}
    end
  end

  # Stripe calls stay outside the reserve lock. A missing customer on an
  # otherwise saved card is the live setup-mode gap; heal it once, then
  # let the existing identifier checks reject a still-incomplete row.
  defp heal_missing_customer(%{stripe_customer_id: customer_id} = payment)
       when not is_binary(customer_id) or customer_id == "" do
    maybe_create_and_attach(payment)
  end

  defp heal_missing_customer(_payment), do: :ok

  defp maybe_create_and_attach(payment) do
    with :ok <- require_identifier(payment.stripe_account_id, :missing_stripe_account),
         :ok <-
           require_identifier(payment.stripe_payment_method_id, :missing_stripe_payment_method),
         {:ok, customer} <-
           StripeAdapter.create_customer(
             customer_params(payment),
             connect_account: payment.stripe_account_id,
             idempotency_key: "setup-customer:#{payment.id}"
           ),
         {:ok, customer_id} <- customer_id(customer),
         {:ok, _method} <-
           StripeAdapter.attach_payment_method(
             payment.stripe_payment_method_id,
             %{customer: customer_id},
             connect_account: payment.stripe_account_id
           ),
         {:ok, _updated} <-
           BookingPaymentQueries.update(payment, %{stripe_customer_id: customer_id}) do
      :ok
    else
      {:error, :missing_stripe_account} -> :ok
      {:error, :missing_stripe_payment_method} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp customer_params(payment) do
    %{email: payment.attendee_email}
    |> then(fn params ->
      if is_binary(payment.attendee_name) and payment.attendee_name != "",
        do: Map.put(params, :name, payment.attendee_name),
        else: params
    end)
  end

  defp customer_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp customer_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp customer_id(_other), do: {:error, :customer_missing}

  defp authorize(%{host_user_id: actor_user_id}, actor_user_id), do: :ok
  defp authorize(_payment, _actor_user_id), do: {:error, :not_authorized}

  defp require_completed(%{status: "completed"}), do: :ok
  defp require_completed(_meeting), do: {:error, :meeting_not_completed}

  defp require_deferred(%{payment_timing: "deferred"}), do: :ok
  defp require_deferred(_payment), do: {:error, :invalid_payment_timing}

  defp require_card_saved(%{status: "card_saved"}), do: :ok
  defp require_card_saved(%{status: "charge_processing"}), do: {:error, :charge_in_progress}
  defp require_card_saved(_payment), do: {:error, :invalid_payment_state}

  defp validate_snapshot(payment, meeting) do
    snapshot = payment.service_snapshot

    with %{
           "service_id" => service_id,
           "amount_cents" => amount_cents,
           "currency" => currency
         }
         when is_integer(amount_cents) and amount_cents > 0 and is_binary(currency) <- snapshot,
         true <- ServiceCatalog.direct_bookable?(service_id),
         true <- amount_cents == payment.amount_cents,
         true <- currency == payment.currency,
         %{"service_id" => ^service_id} <- meeting.service_snapshot,
         true <- meeting.service_snapshot == snapshot do
      {:ok, amount_cents, currency}
    else
      _mismatch -> {:error, :invalid_service_snapshot}
    end
  end

  defp require_identifier(value, _error) when is_binary(value) and value != "", do: :ok
  defp require_identifier(_value, error), do: {:error, error}

  defp reserve_payment(payment) do
    BookingPaymentQueries.update(payment, %{
      status: "charge_processing",
      charge_attempt: payment.charge_attempt + 1,
      charge_requested_at: DateTime.utc_now(:second),
      last_error_code: nil
    })
  end

  defp audit(payment, actor_user_id, amount_cents) do
    BookingPaymentAudits.append(%{
      booking_payment_id: payment.id,
      meeting_id: payment.meeting_id,
      actor_type: "owner",
      actor_user_id: actor_user_id,
      action: "charge_requested",
      attempt: payment.charge_attempt,
      amount_cents: amount_cents,
      result: "reserved"
    })
  end

  defp enqueue(payment) do
    %{
      "booking_payment_id" => payment.id,
      "charge_attempt" => payment.charge_attempt
    }
    |> Oban.Job.new(worker: @worker, queue: :payments)
    |> Oban.insert()
  end
end
