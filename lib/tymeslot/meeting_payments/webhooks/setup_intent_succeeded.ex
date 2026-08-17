defmodule Tymeslot.MeetingPayments.Webhooks.SetupIntentSucceeded do
  @moduledoc """
  Confirms a deferred booking after Stripe saves the customer's card.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.CardSetupConfirmation

  @event_type "setup_intent.succeeded"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case lookup_payment(object) do
      nil ->
        Logger.info("setup_intent.succeeded: no booking_payment matched",
          setup_intent_id: object["id"]
        )

        {:ok, :ok}

      payment ->
        classify(
          CardSetupConfirmation.apply(payment, %{
            event_id: event_id,
            event_type: @event_type,
            stripe_account_id: event["account"],
            stripe_setup_intent_id: object["id"],
            stripe_customer_id: object["customer"],
            stripe_payment_method_id: object["payment_method"],
            meeting_id: metadata(object, "meeting_id"),
            service_id: metadata(object, "service_id"),
            service_version: metadata(object, "service_version")
          })
        )
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp lookup_payment(%{"id" => setup_intent_id} = object) when is_binary(setup_intent_id) do
    BookingPaymentQueries.by_setup_intent_id(setup_intent_id) ||
      lookup_by_metadata(object)
  end

  defp lookup_payment(object), do: lookup_by_metadata(object)

  defp lookup_by_metadata(object) do
    case metadata(object, "booking_payment_id") do
      id when is_binary(id) -> BookingPaymentQueries.get(id)
      _missing -> nil
    end
  end

  defp metadata(%{"metadata" => metadata}, key) when is_map(metadata), do: metadata[key]
  defp metadata(_object, _key), do: nil
end
