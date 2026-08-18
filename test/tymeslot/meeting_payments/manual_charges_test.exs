defmodule Tymeslot.MeetingPayments.ManualChargesTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ManualCharges
  alias Tymeslot.MeetingPayments.Workers.ChargeBookingPayment

  setup :verify_on_exit!

  @snapshot %{
    "service_id" => "discovery-call",
    "service_name" => "Discovery call",
    "amount_cents" => 4_900,
    "currency" => "usd",
    "duration_minutes" => 30,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  test "reserves the immutable snapshot charge, audits it, and enqueues one job" do
    %{host: host, payment: payment} = card_saved_payment()

    assert {:ok, reservation} = ManualCharges.reserve(payment.id, host.id)
    assert reservation.amount_cents == 4_900
    assert reservation.currency == "usd"
    assert reservation.charge_attempt == 1
    assert reservation.booking_payment.status == "charge_processing"
    assert %DateTime{} = reservation.booking_payment.charge_requested_at

    persisted = BookingPaymentQueries.get(payment.id)
    assert persisted.status == "charge_processing"
    assert persisted.charge_attempt == 1

    assert [audit] = BookingPaymentAudits.list_for_payment(payment.id)
    assert audit.actor_type == "owner"
    assert audit.actor_user_id == host.id
    assert audit.action == "charge_requested"
    assert audit.result == "reserved"
    assert audit.attempt == 1
    assert audit.amount_cents == 4_900

    assert_enqueued(
      worker: ChargeBookingPayment,
      args: %{"booking_payment_id" => payment.id, "charge_attempt" => 1}
    )

    assert [_job] = all_enqueued(worker: ChargeBookingPayment)
  end

  test "rejects a foreign host without changing payment state" do
    %{payment: payment} = card_saved_payment()
    foreign_host = insert(:user)

    assert {:error, :not_authorized} = ManualCharges.reserve(payment.id, foreign_host.id)
    assert_unchanged(payment)
  end

  test "does not create a Stripe customer for a foreign host" do
    %{payment: payment} = card_saved_payment(stripe_customer_id: nil)
    foreign_host = insert(:user)

    assert {:error, :not_authorized} = ManualCharges.reserve(payment.id, foreign_host.id)
    assert is_nil(BookingPaymentQueries.get(payment.id).stripe_customer_id)
  end

  test "requires a completed meeting" do
    %{host: host, payment: payment} = card_saved_payment(meeting_status: "confirmed")

    assert {:error, :meeting_not_completed} = ManualCharges.reserve(payment.id, host.id)
    assert_unchanged(payment)
  end

  test "requires deferred payment timing" do
    %{host: host, payment: payment} = card_saved_payment(payment_timing: "upfront")

    assert {:error, :invalid_payment_timing} = ManualCharges.reserve(payment.id, host.id)
    assert_unchanged(payment)
  end

  test "requires card_saved payment state and rejects a repeated reservation" do
    %{host: host, payment: payment} = card_saved_payment()

    assert {:ok, _reservation} = ManualCharges.reserve(payment.id, host.id)
    assert {:error, :charge_in_progress} = ManualCharges.reserve(payment.id, host.id)
    assert [_job] = all_enqueued(worker: ChargeBookingPayment)
  end

  test "requires immutable snapshot amount and currency to match payment fields" do
    %{host: host, payment: payment} = card_saved_payment(amount_cents: 14_000)

    assert {:error, :invalid_service_snapshot} = ManualCharges.reserve(payment.id, host.id)
    assert_unchanged(payment)
  end

  test "rejects a completed generic meeting without a service snapshot" do
    %{host: host, payment: payment} = card_saved_payment(meeting_snapshot: %{})

    assert {:error, :invalid_service_snapshot} = ManualCharges.reserve(payment.id, host.id)
    assert_unchanged(payment)
  end

  test "requires meeting and payment snapshots to identify the same direct service" do
    meeting_snapshot =
      @snapshot
      |> Map.put("service_id", "online-consultation")
      |> Map.put("service_name", "Online behavior consultation")

    %{host: host, payment: payment} = card_saved_payment(meeting_snapshot: meeting_snapshot)

    assert {:error, :invalid_service_snapshot} = ManualCharges.reserve(payment.id, host.id)
    assert_unchanged(payment)
  end

  test "requires Stripe account and payment method identifiers" do
    for {field, error} <- [
          {:stripe_account_id, :missing_stripe_account},
          {:stripe_payment_method_id, :missing_stripe_payment_method}
        ] do
      %{host: host, payment: payment} = card_saved_payment([{field, ""}])

      assert {:error, ^error} = ManualCharges.reserve(payment.id, host.id)
      assert_unchanged(payment)
    end
  end

  test "attaches a missing customer to the saved card before reserving" do
    %{host: host, payment: payment} = card_saved_payment(stripe_customer_id: nil)

    expect(StripeAdapterMock, :create_customer, fn params, opts ->
      assert opts[:connect_account] == "acct_HOST"
      assert params.email == payment.attendee_email
      {:ok, %{"id" => "cus_HEALED"}}
    end)

    expect(StripeAdapterMock, :attach_payment_method, fn "pm_CARD", params, opts ->
      assert opts[:connect_account] == "acct_HOST"
      assert params.customer == "cus_HEALED"
      {:ok, %{"id" => "pm_CARD"}}
    end)

    assert {:ok, reservation} = ManualCharges.reserve(payment.id, host.id)
    assert reservation.booking_payment.stripe_customer_id == "cus_HEALED"
    assert BookingPaymentQueries.get(payment.id).stripe_customer_id == "cus_HEALED"
  end

  test "still rejects a charge when no customer can be created" do
    %{host: host, payment: payment} =
      card_saved_payment(stripe_customer_id: nil, stripe_payment_method_id: "")

    assert {:error, :missing_stripe_customer} = ManualCharges.reserve(payment.id, host.id)
    assert_unchanged(payment)
  end

  defp card_saved_payment(attrs \\ []) do
    {meeting_status, attrs} = Keyword.pop(attrs, :meeting_status, "completed")
    {meeting_snapshot, attrs} = Keyword.pop(attrs, :meeting_snapshot, @snapshot)
    host = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: host.id,
        status: meeting_status,
        service_snapshot: meeting_snapshot
      )

    defaults = [
      meeting: meeting,
      host_user_id: host.id,
      stripe_account_id: "acct_HOST",
      stripe_customer_id: "cus_CLIENT",
      stripe_payment_method_id: "pm_CARD",
      payment_timing: "deferred",
      service_snapshot: @snapshot,
      amount_cents: 4_900,
      currency: "usd",
      application_fee_cents: 0,
      status: "card_saved",
      charge_attempt: 0
    ]

    %{host: host, payment: insert(:booking_payment, Keyword.merge(defaults, attrs))}
  end

  defp assert_unchanged(payment) do
    persisted = BookingPaymentQueries.get(payment.id)
    assert persisted.status == payment.status
    assert persisted.charge_attempt == payment.charge_attempt
    assert persisted.charge_requested_at == payment.charge_requested_at
    assert BookingPaymentAudits.list_for_payment(payment.id) == []
    assert all_enqueued(worker: ChargeBookingPayment) == []
  end
end
