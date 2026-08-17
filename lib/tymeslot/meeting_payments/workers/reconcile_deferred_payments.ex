defmodule Tymeslot.MeetingPayments.Workers.ReconcileDeferredPayments do
  @moduledoc """
  Sweeps stale deferred setup checkouts and applies the same transitions as
  the setup webhooks. It never creates a charge.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 1,
    unique: [period: 60]

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired

  @stale_after_seconds 60 * 60

  @type sweep_result :: %{
          reconciled: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@stale_after_seconds, :second)
      |> DateTime.truncate(:second)

    payments = BookingPaymentQueries.list_stale_setup_pending(cutoff)

    result =
      Enum.reduce(payments, %{reconciled: 0, skipped: 0, errors: 0}, fn payment, acc ->
        case reconcile_one(payment) do
          :reconciled -> Map.update!(acc, :reconciled, &(&1 + 1))
          :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
          :error -> Map.update!(acc, :errors, &(&1 + 1))
        end
      end)

    Logger.info("ReconcileDeferredPayments sweep complete",
      reconciled: result.reconciled,
      skipped: result.skipped,
      errors: result.errors
    )

    {:ok, result}
  end

  @spec reconcile_one(BookingPaymentSchema.t()) :: :reconciled | :skipped | :error
  defp reconcile_one(%BookingPaymentSchema{stripe_checkout_session_id: session_id} = payment)
       when is_binary(session_id) do
    case StripeAdapter.retrieve_checkout_session(session_id,
           connect_account: payment.stripe_account_id,
           expand: ["setup_intent"]
         ) do
      {:ok, session} -> dispatch(payment, session)
      {:error, reason} -> log_error(payment, reason)
    end
  end

  defp dispatch(payment, session) do
    cond do
      setup_complete?(session) ->
        handle_or_log(payment, &CheckoutSessionCompleted.handle/1, synthetic_event(payment, session))
        :reconciled

      expired?(session) ->
        handle_or_log(payment, &CheckoutSessionExpired.handle/1, synthetic_event(payment, session))
        :reconciled

      true ->
        :skipped
    end
  end

  defp setup_complete?(session) do
    status(session) == "complete" or present?(setup_intent_id(session))
  end

  defp expired?(session), do: status(session) == "expired"

  defp handle_or_log(payment, handler, event) do
    case handler.(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("ReconcileDeferredPayments handler failed",
          booking_payment_id: payment.id,
          error_category: error_category(reason)
        )

        :ok
    end
  end

  defp synthetic_event(payment, session) do
    %{
      "id" => "reconcile-setup:#{payment.stripe_checkout_session_id}",
      "account" => payment.stripe_account_id,
      "data" => %{
        "object" =>
          session
          |> stringify_keys()
          |> Map.put_new("client_reference_id", payment.meeting_id)
          |> Map.put_new("mode", "setup")
      }
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value), do: value

  defp status(session) when is_map(session) do
    Map.get(session, "status") || Map.get(session, :status)
  end

  defp setup_intent_id(session) when is_map(session) do
    case Map.get(session, "setup_intent") || Map.get(session, :setup_intent) do
      %{"id" => id} -> id
      %{id: id} -> id
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp present?(value) when is_binary(value), do: byte_size(value) > 0
  defp present?(_value), do: false

  defp error_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_category(_reason), do: "stripe_retrieve_failed"

  defp log_error(payment, reason) do
    Logger.warning("ReconcileDeferredPayments could not retrieve Stripe session",
      booking_payment_id: payment.id,
      stripe_checkout_session_id: payment.stripe_checkout_session_id,
      error_category: error_category(reason)
    )

    :error
  end
end
