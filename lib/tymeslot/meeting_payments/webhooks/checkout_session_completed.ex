defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted do
  @moduledoc """
  Handler for the Stripe `checkout.session.completed` Connect event.

  Marks the matching `booking_payment` as paid, transitions the meeting
  from `awaiting_payment` to `confirmed`, and triggers the same
  side-effect pipeline (calendar push + confirmation emails) that the
  free booking flow uses. The whole state mutation runs inside a single
  `Repo.transaction/1` so a crash mid-flow rolls back cleanly.

  Idempotent — replaying an event whose id matches the stored
  `last_event_id` is a no-op, as is delivering an event for a meeting
  that is no longer in `awaiting_payment`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.Webhooks.CardSetupConfirmation
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker

  @event_type "checkout.session.completed"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case lookup_payment(object) do
      nil ->
        Logger.info("checkout.session.completed: no booking_payment matched",
          checkout_session_id: object["id"],
          meeting_id: object["client_reference_id"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        Logger.info("checkout.session.completed: idempotent replay", event_id: event_id)
        {:ok, :idempotent_replay}

      payment ->
        classify(run(payment, event_id, event, object))
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp lookup_payment(%{"client_reference_id" => meeting_id} = object)
       when is_binary(meeting_id) do
    BookingPaymentQueries.by_meeting_id(meeting_id) || lookup_by_session(object)
  end

  defp lookup_payment(object), do: lookup_by_session(object)

  defp lookup_by_session(%{"id" => session_id}) when is_binary(session_id) do
    BookingPaymentQueries.by_checkout_session(session_id)
  end

  defp lookup_by_session(_object), do: nil

  defp run(%{payment_timing: "deferred"} = payment, event_id, event, object) do
    if get_in(object, ["metadata", "payment_purpose"]) == "recovery" do
      apply_recovery(payment, event, object)
    else
      CardSetupConfirmation.apply(payment, %{
        event_id: event_id,
        event_type: @event_type,
        stripe_account_id: event["account"],
        stripe_setup_intent_id: setup_intent_id(object),
        meeting_id: object["client_reference_id"],
        service_id: get_in(object, ["metadata", "service_id"]),
        service_version: get_in(object, ["metadata", "service_version"])
      })
    end
  end

  defp run(payment, event_id, _event, object), do: run_upfront(payment, event_id, object)

  defp apply_recovery(%{status: status} = payment, event, object)
       when status in ["charge_failed", "action_required"] do
    charge_id = fetch_recovery_charge_id(payment, object)

    if is_binary(charge_id) do
      case Repo.transaction(fn ->
             with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
                  :ok <- validate_recovery(locked, event, object),
                  {:ok, paid} <-
                    BookingPaymentQueries.update(locked, %{
                      status: "paid",
                      stripe_payment_intent_id: object["payment_intent"],
                      stripe_charge_id: charge_id,
                      paid_at: DateTime.utc_now(:second),
                      last_error_code: nil
                    }),
                  {:ok, _audit} <-
                    BookingPaymentAudits.append(%{
                      booking_payment_id: paid.id,
                      meeting_id: paid.meeting_id,
                      actor_type: "stripe",
                      action: "recovery_succeeded",
                      attempt: paid.charge_attempt,
                      amount_cents: paid.service_snapshot["amount_cents"],
                      result: "paid",
                      stripe_object_id: paid.stripe_charge_id
                    }) do
               paid
             else
               :no_op -> :no_op
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :recovery_charge_unavailable}
    end
  end

  defp apply_recovery(_payment, _event, _object), do: :ok

  defp validate_recovery(%{status: status}, _event, _object)
       when status not in ["charge_failed", "action_required"],
       do: :no_op

  defp validate_recovery(payment, event, object) do
    metadata = object["metadata"] || %{}

    if payment.stripe_recovery_session_id == object["id"] and
         payment.stripe_account_id == event["account"] and
         payment.id == metadata["booking_payment_id"] and
         payment.meeting_id == metadata["meeting_id"] and
         payment.service_snapshot["service_id"] == metadata["service_id"] and
         payment.charge_attempt == parse_attempt(metadata["charge_attempt"]) and
         is_binary(object["payment_intent"]) do
      :ok
    else
      :no_op
    end
  end

  defp recovery_charge_id(%{"latest_charge" => id}) when is_binary(id), do: id

  defp recovery_charge_id(%{"payment_intent_data" => %{"latest_charge" => id}})
       when is_binary(id),
       do: id

  defp recovery_charge_id(_object), do: nil

  defp fetch_recovery_charge_id(payment, object) do
    recovery_charge_id(object) ||
      retrieve_recovery_charge_id(payment, object["payment_intent"])
  end

  defp retrieve_recovery_charge_id(payment, intent_id) when is_binary(intent_id) do
    case StripeAdapter.retrieve_payment_intent(intent_id,
           connect_account: payment.stripe_account_id
         ) do
      {:ok, intent} -> extract_charge_id(intent)
      {:error, _reason} -> nil
    end
  end

  defp retrieve_recovery_charge_id(_payment, _intent_id), do: nil

  defp parse_attempt(value) when is_integer(value), do: value

  defp parse_attempt(value) when is_binary(value) do
    case Integer.parse(value) do
      {attempt, ""} -> attempt
      _invalid -> nil
    end
  end

  defp parse_attempt(_value), do: nil

  defp run_upfront(payment, event_id, object) do
    case Repo.transaction(fn -> run_in_transaction(payment, event_id, object) end) do
      {:ok, {:advanced, paid, meeting}} ->
        # Backfill stripe_charge_id outside the transaction — this requires a
        # Stripe API call (expanding payment_intent.latest_charge) which must
        # not be made inside a DB transaction.  Charge handlers (refund/dispute)
        # all look up the row via stripe_charge_id so this field is required for
        # them to work.  A failure here is logged but does not roll back the
        # payment transition; the reconciler can retry if needed.
        backfill_charge_id(paid, object)
        emit_payment_succeeded(paid, meeting)
        broadcast_paid(meeting.id)
        enqueue_post_payment_effects(meeting, paid)
        :ok

      {:ok, {:recovered, paid, meeting}} ->
        Logger.warning(
          "checkout.session.completed: recovery transition — completed event arrived after expiry",
          meeting_id: meeting.id,
          payment_id: paid.id,
          event_id: event_id
        )

        backfill_charge_id(paid, object)
        emit_payment_succeeded(paid, meeting)
        broadcast_paid(meeting.id)
        enqueue_post_payment_effects(meeting, paid)
        :ok

      {:ok, :no_op} ->
        :ok

      {:error, reason} ->
        Logger.error("checkout.session.completed handler failed",
          event_id: event_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # The checkout.session.completed event carries payment_intent as a bare ID.
  # The actual charge ID lives on PaymentIntent.latest_charge, which requires
  # a Stripe API expansion call.  We write it as a separate DB update so the
  # charge.refunded / charge.dispute.* handlers can look up the row.
  defp backfill_charge_id(payment, object) do
    with intent_id when is_binary(intent_id) <- object["payment_intent"],
         {:ok, intent} <-
           StripeAdapter.retrieve_payment_intent(intent_id,
             connect_account: payment.stripe_account_id
           ),
         charge_id when is_binary(charge_id) <- extract_charge_id(intent) do
      case BookingPaymentQueries.update(payment, %{stripe_charge_id: charge_id}) do
        {:ok, _updated} ->
          :ok

        {:error, reason} ->
          Logger.error("checkout.session.completed: failed to persist stripe_charge_id",
            payment_id: payment.id,
            reason: inspect(reason)
          )
      end
    else
      nil ->
        Logger.warning("checkout.session.completed: charge ID not available on payment intent",
          payment_id: payment.id
        )

      {:error, reason} ->
        Logger.error(
          "checkout.session.completed: failed to retrieve payment intent for charge id",
          payment_id: payment.id,
          reason: inspect(reason)
        )
    end
  end

  # The mock adapter (and `construct_webhook_event`) yields string-keyed maps;
  # the real Stripity adapter returns an atom-keyed `%Stripe.PaymentIntent{}`
  # whose expanded `latest_charge` is a `%Stripe.Charge{}` struct. Handle both
  # so the charge id is captured regardless of adapter — without it, every
  # refund/dispute lookup (keyed on `stripe_charge_id`) fails.
  defp extract_charge_id(%{"latest_charge" => %{"id" => id}}) when is_binary(id), do: id
  defp extract_charge_id(%{"latest_charge" => id}) when is_binary(id), do: id
  defp extract_charge_id(%{latest_charge: %{id: id}}) when is_binary(id), do: id
  defp extract_charge_id(%{latest_charge: id}) when is_binary(id), do: id
  defp extract_charge_id(_other), do: nil

  defp run_in_transaction(payment, event_id, object) do
    with {:ok, meeting} <- fetch_meeting(payment.meeting_id),
         {:proceed, transition} <- check_transition(meeting, payment),
         {:ok, paid} <- mark_paid(payment, event_id, object),
         {:ok, confirmed} <- MeetingQueries.update_meeting(meeting, %{status: "confirmed"}) do
      {transition, paid, confirmed}
    else
      :no_op ->
        :no_op

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp fetch_meeting(nil), do: {:error, :meeting_missing}
  defp fetch_meeting(meeting_id), do: MeetingQueries.get_meeting(meeting_id)

  # Determine the transition type based on meeting and payment state.
  # Returns `{:proceed, type}` to continue the with-chain, or `:no_op` to
  # short-circuit (falls to the else clause).
  #
  # Transitions:
  #   :advanced  — normal happy path (meeting awaiting_payment)
  #   :recovered — race: completed event arrived after the expired webhook ran;
  #                both events are authoritative; we recover by re-confirming
  #   :no_op     — meeting already in a non-recoverable terminal state; skip
  defp check_transition(%{status: "awaiting_payment"}, _payment), do: {:proceed, :advanced}

  defp check_transition(%{status: "expired"}, %{status: payment_status})
       when payment_status in ["failed", "cancelled"],
       do: {:proceed, :recovered}

  defp check_transition(_meeting, _payment), do: :no_op

  defp mark_paid(payment, event_id, object) do
    case BookingPaymentQueries.update(payment, %{
           status: paid_status(payment.status),
           paid_at: DateTime.utc_now(:second),
           stripe_payment_intent_id: object["payment_intent"],
           last_event_id: event_id
         }) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_paid)
        result

      {:error, _changeset} = err ->
        err
    end
  end

  # A dispute can land before this completed event (the charge is disputed the
  # instant it is captured). When it has, the row is already `disputed` — record
  # the payment_intent and timestamp but keep the dispute status rather than
  # clobbering it back to `paid`.
  defp paid_status("disputed"), do: "disputed"
  defp paid_status(_status), do: "paid"

  defp setup_intent_id(%{"setup_intent" => %{"id" => id}}) when is_binary(id), do: id
  defp setup_intent_id(%{"setup_intent" => id}) when is_binary(id), do: id
  defp setup_intent_id(_object), do: nil

  defp emit_payment_succeeded(paid, meeting) do
    :telemetry.execute(
      [:tymeslot, :meeting_payments, :booking_payment, :succeeded],
      %{count: 1},
      %{currency: paid.currency, has_video: not is_nil(meeting.video_integration_id)}
    )
  end

  defp broadcast_paid(meeting_id) do
    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :paid)
  end

  defp enqueue_post_payment_effects(meeting, _payment) do
    if meeting.video_integration_id do
      VideoRoomWorker.schedule_video_room_creation_with_emails(meeting.id)
    else
      _result = Events.meeting_created(meeting)
      :ok
    end
  end
end
