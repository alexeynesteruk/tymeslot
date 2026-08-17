defmodule Tymeslot.MeetingPayments.Webhooks.WebhookProcessor do
  @moduledoc """
  Verifies a Stripe Connect webhook payload and dispatches to a per-event
  handler.

  Distinct from `Tymeslot.Payments.Webhooks.WebhookProcessor` — that one
  handles platform-level subscription events; this one handles
  Connect-account events tied to booking payments. Different signing
  secrets, different registries, different handlers.

  Replay protection is handled by `construct_webhook_event/3` itself: Stripe's
  signature verification rejects events whose `t=` timestamp is older than 300
  seconds. A secondary `event["created"]` age check is redundant and harmful —
  Stripe retries carry the original `created` timestamp, so such a check would
  permanently drop any event whose first delivery failed transiently.
  Per-event idempotency is provided by `last_event_id` on `booking_payments`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.ProcessedStripeEvents
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Webhooks.WebhookRegistry
  alias Tymeslot.Utils.MapKeys

  @type process_result :: :ok | {:error, term()}

  @spec process(binary(), String.t(), String.t()) :: process_result()
  def process(payload, signature, secret) do
    case StripeAdapter.construct_webhook_event(payload, signature, secret) do
      {:ok, event} ->
        dispatch(event)

      {:error, reason} ->
        # Normalise signature/payload errors to a single atom so the controller
        # can distinguish permanent rejections from transient handler failures.
        Logger.warning("Connect webhook signature verification failed", reason: inspect(reason))
        {:error, :signature_failure}
    end
  end

  defp dispatch(event) do
    type = MapKeys.get(event, :type)
    event_id = MapKeys.get(event, :id)

    case WebhookRegistry.handler_for(type) do
      nil ->
        Logger.info("Ignoring unhandled Connect webhook event", event_type: type)
        :ok

      handler ->
        process_handled(event, event_id, type, handler)
    end
  end

  defp process_handled(event, event_id, type, handler) when is_binary(event_id) do
    case ProcessedStripeEvents.claim(event_id, type) do
      {:ok, :duplicate} ->
        Logger.info("Ignoring duplicate Connect webhook event",
          event_type: type,
          event_id: event_id
        )

        :ok

      {:ok, :claimed} ->
        Logger.info("Dispatching Connect webhook event", event_type: type, event_id: event_id)
        finalize_claim(event_id, handler.handle(event))

      {:error, reason} ->
        Logger.error("Failed to claim Connect webhook event",
          event_type: type,
          event_id: event_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp process_handled(event, _event_id, type, handler) do
    Logger.info("Dispatching Connect webhook event without durable claim", event_type: type)
    handler.handle(event)
  end

  defp finalize_claim(event_id, :ok) do
    _result = ProcessedStripeEvents.complete(event_id)
    :ok
  end

  defp finalize_claim(event_id, {:error, reason} = error) do
    _result = ProcessedStripeEvents.fail(event_id, inspect(reason))
    error
  end
end
