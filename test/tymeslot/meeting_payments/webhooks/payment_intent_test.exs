defmodule Tymeslot.MeetingPayments.Webhooks.PaymentIntentTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Webhooks.PaymentIntentPaymentFailed
  alias Tymeslot.MeetingPayments.Webhooks.PaymentIntentSucceeded

  @snapshot %{
    "service_id" => "discovery-call",
    "service_name" => "Discovery call",
    "amount_cents" => 4_900,
    "currency" => "usd",
    "duration_minutes" => 30,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  test "matching success advances only the active attempt and stores charge" do
    payment = processing_payment()

    assert :ok =
             PaymentIntentSucceeded.handle(
               event("evt_OK", "pi_OK", payment, "succeeded", "ch_OK")
             )

    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "paid"
    assert reloaded.stripe_payment_intent_id == "pi_OK"
    assert reloaded.stripe_charge_id == "ch_OK"

    assert :ok =
             PaymentIntentSucceeded.handle(
               event("evt_REPLAY", "pi_OK", payment, "succeeded", "ch_OK")
             )

    assert length(BookingPaymentAudits.list_for_payment(payment.id)) == 1
  end

  test "failure records a decline and a later success cannot regress or replace its intent" do
    payment = processing_payment()

    assert :ok =
             PaymentIntentPaymentFailed.handle(
               event("evt_FAIL", "pi_FAIL", payment, "requires_payment_method", nil)
             )

    failed = BookingPaymentQueries.get(payment.id)
    assert failed.status == "charge_failed"
    assert failed.stripe_payment_intent_id == "pi_FAIL"

    assert :ok =
             PaymentIntentSucceeded.handle(
               event("evt_LATE", "pi_OTHER", payment, "succeeded", "ch_OTHER")
             )

    unchanged = BookingPaymentQueries.get(payment.id)
    assert unchanged.status == "charge_failed"
    assert unchanged.stripe_payment_intent_id == "pi_FAIL"
  end

  test "connected-account and attempt mismatches fail closed" do
    payment = processing_payment()

    wrong_account =
      event("evt_ACCOUNT", "pi_X", payment, "succeeded", "ch_X")
      |> Map.put("account", "acct_OTHER")

    assert {:error, :payment_intent_mismatch} = PaymentIntentSucceeded.handle(wrong_account)

    wrong_attempt =
      event("evt_ATTEMPT", "pi_X", payment, "succeeded", "ch_X")
      |> put_in(["data", "object", "metadata", "charge_attempt"], "2")

    assert {:error, :payment_intent_mismatch} = PaymentIntentSucceeded.handle(wrong_attempt)
    assert BookingPaymentQueries.get(payment.id).status == "charge_processing"
  end

  for outcome <- [:succeeded, :failed] do
    test "#{outcome} rejects a missing or blank PaymentIntent ID" do
      payment = processing_payment()

      handler =
        if unquote(outcome) == :succeeded,
          do: PaymentIntentSucceeded,
          else: PaymentIntentPaymentFailed

      for intent_id <- [nil, "", "   "] do
        webhook = event("evt_#{inspect(intent_id)}", intent_id, payment, "succeeded", "ch_X")
        assert {:error, :payment_intent_mismatch} = handler.handle(webhook)
      end

      assert BookingPaymentQueries.get(payment.id).status == "charge_processing"
    end
  end

  defp processing_payment do
    host = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: host.id,
        status: "completed",
        service_snapshot: @snapshot
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: host.id,
      stripe_account_id: "acct_HOST",
      payment_timing: "deferred",
      service_snapshot: @snapshot,
      amount_cents: 4_900,
      currency: "usd",
      status: "charge_processing",
      charge_attempt: 1
    )
  end

  defp event(event_id, intent_id, payment, status, charge_id) do
    %{
      "id" => event_id,
      "account" => "acct_HOST",
      "data" => %{
        "object" => %{
          "id" => intent_id,
          "status" => status,
          "latest_charge" => charge_id,
          "last_payment_error" => %{"code" => "card_declined"},
          "metadata" => %{
            "booking_payment_id" => payment.id,
            "meeting_id" => payment.meeting_id,
            "service_id" => "discovery-call",
            "charge_attempt" => "1"
          }
        }
      }
    }
  end
end
