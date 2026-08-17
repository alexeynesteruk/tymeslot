defmodule Tymeslot.MeetingPayments.PaymentTimingTest do
  use ExUnit.Case, async: true

  alias Tymeslot.MeetingPayments.PaymentTiming

  test "accepts only upfront and deferred timing" do
    assert PaymentTiming.valid?("upfront")
    assert PaymentTiming.valid?("deferred")
    refute PaymentTiming.valid?("later")
    refute PaymentTiming.valid?(nil)
  end

  test "deferred timing is distinct from existing upfront checkout" do
    assert PaymentTiming.deferred?("deferred")
    refute PaymentTiming.deferred?("upfront")
  end

  test "a deferred payment requires snapshot, Stripe account, amount, and currency" do
    snapshot = %{
      "service_id" => "discovery-call",
      "service_name" => "Discovery call",
      "amount_cents" => 4_900,
      "currency" => "usd",
      "duration_minutes" => 30,
      "delivery_mode" => "virtual",
      "event_type_version" => 1
    }

    assert {:ok, "deferred"} =
             PaymentTiming.validate_deferred(%{
               service_snapshot: snapshot,
               stripe_account_id: "acct_test",
               amount_cents: 4_900,
               currency: "usd"
             })

    assert {:error, :missing_service_snapshot} =
             PaymentTiming.validate_deferred(%{
               stripe_account_id: "acct_test",
               amount_cents: 4_900,
               currency: "usd"
             })

    assert {:error, :missing_stripe_account} =
             PaymentTiming.validate_deferred(%{
               service_snapshot: snapshot,
               amount_cents: 4_900,
               currency: "usd"
             })

    assert {:error, :missing_amount} =
             PaymentTiming.validate_deferred(%{
               service_snapshot: snapshot,
               stripe_account_id: "acct_test",
               currency: "usd"
             })

    assert {:error, :missing_currency} =
             PaymentTiming.validate_deferred(%{
               service_snapshot: snapshot,
               stripe_account_id: "acct_test",
               amount_cents: 4_900
             })
  end
end
