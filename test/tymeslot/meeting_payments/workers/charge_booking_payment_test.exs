defmodule Tymeslot.MeetingPayments.Workers.ChargeBookingPaymentTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.ChargeBookingPayment

  @snapshot %{
    "service_id" => "online-consultation",
    "service_name" => "Online behavior consultation",
    "amount_cents" => 14_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  setup :verify_on_exit!
  setup :set_mox_from_context

  test "charges the immutable snapshot off session with a stable idempotency key" do
    payment = processing_payment()

    expect(StripeAdapterMock, :create_payment_intent, fn params, opts ->
      assert params == %{
               amount: 14_000,
               currency: "usd",
               customer: "cus_CLIENT",
               payment_method: "pm_CARD",
               off_session: true,
               confirm: true,
               receipt_email: "attendee@example.com",
               metadata: %{
                 meeting_id: payment.meeting_id,
                 booking_payment_id: payment.id,
                 service_id: "online-consultation",
                 charge_attempt: 1
               }
             }

      assert opts[:connect_account] == "acct_HOST"
      assert opts[:idempotency_key] == "booking-charge:#{payment.id}:1"

      {:ok, %{"id" => "pi_OK", "status" => "succeeded", "latest_charge" => "ch_OK"}}
    end)

    assert :ok = perform_job(ChargeBookingPayment, job_args(payment))

    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "paid"
    assert reloaded.stripe_payment_intent_id == "pi_OK"
    assert reloaded.stripe_charge_id == "ch_OK"
    assert %DateTime{} = reloaded.paid_at

    assert Enum.any?(BookingPaymentAudits.list_for_payment(payment.id), fn audit ->
             audit.action == "charge_succeeded" and audit.result == "paid"
           end)
  end

  test "records authentication required without retrying" do
    payment = processing_payment()

    expect(StripeAdapterMock, :create_payment_intent, fn _params, _opts ->
      {:ok,
       %{
         "id" => "pi_ACTION",
         "status" => "requires_action",
         "last_payment_error" => %{"code" => "authentication_required"}
       }}
    end)

    assert :ok = perform_job(ChargeBookingPayment, job_args(payment))
    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "action_required"
    assert reloaded.last_error_code == "authentication_required"
  end

  test "records a decline without automatic retry" do
    payment = processing_payment()

    expect(StripeAdapterMock, :create_payment_intent, fn _params, _opts ->
      {:ok,
       %{
         "id" => "pi_DECLINED",
         "status" => "requires_payment_method",
         "last_payment_error" => %{"code" => "card_declined"}
       }}
    end)

    assert :ok = perform_job(ChargeBookingPayment, job_args(payment))
    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "charge_failed"
    assert reloaded.last_error_code == "card_declined"
  end

  test "leaves an uncertain Stripe result processing for reconciliation" do
    payment = processing_payment()
    expect(StripeAdapterMock, :create_payment_intent, fn _params, _opts -> {:error, :timeout} end)

    assert :ok = perform_job(ChargeBookingPayment, job_args(payment))
    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "charge_processing"
    assert reloaded.last_error_code == "uncertain_result"
  end

  test "stale jobs do not call Stripe or change a later attempt" do
    payment = processing_payment(charge_attempt: 2)

    assert :ok =
             perform_job(ChargeBookingPayment, %{
               "booking_payment_id" => payment.id,
               "charge_attempt" => 1
             })

    assert BookingPaymentQueries.get(payment.id).charge_attempt == 2
  end

  defp processing_payment(attrs \\ []) do
    host = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: host.id,
        status: "completed",
        service_snapshot: @snapshot
      )

    defaults = [
      meeting: meeting,
      host_user_id: host.id,
      attendee_email: "attendee@example.com",
      stripe_account_id: "acct_HOST",
      stripe_customer_id: "cus_CLIENT",
      stripe_payment_method_id: "pm_CARD",
      payment_timing: "deferred",
      service_snapshot: @snapshot,
      amount_cents: 14_000,
      currency: "usd",
      application_fee_cents: 0,
      status: "charge_processing",
      charge_attempt: 1,
      charge_requested_at: DateTime.utc_now(:second)
    ]

    insert(:booking_payment, Keyword.merge(defaults, attrs))
  end

  defp job_args(payment),
    do: %{"booking_payment_id" => payment.id, "charge_attempt" => payment.charge_attempt}
end
