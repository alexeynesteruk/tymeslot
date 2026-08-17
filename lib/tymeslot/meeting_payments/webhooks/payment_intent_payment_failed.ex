defmodule Tymeslot.MeetingPayments.Webhooks.PaymentIntentPaymentFailed do
  @moduledoc "Applies monotonic deferred PaymentIntent failure events."

  alias Tymeslot.MeetingPayments.Webhooks.PaymentIntentSucceeded

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event), do: PaymentIntentSucceeded.apply_event(event, :failed)
end
