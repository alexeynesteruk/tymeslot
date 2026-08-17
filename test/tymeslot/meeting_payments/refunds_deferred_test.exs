defmodule Tymeslot.MeetingPayments.RefundsDeferredTest do
  use Tymeslot.DataCase, async: false

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!
  setup :set_mox_from_context

  test "owner refunds a deferred charge by stored Charge ID" do
    %{host: host, payment: payment} = paid_payment()

    expect(StripeAdapterMock, :create_refund, fn params, opts ->
      assert params.charge == "ch_DEFERRED"
      assert params.amount == 4_900
      assert opts[:idempotency_key] == "refund:#{payment.id}:4900:4900"
      {:ok, %{"id" => "re_OK"}}
    end)

    assert {:ok, refunded} = Refunds.issue_refund(payment.id, host.id, 4_900)
    assert refunded.status == "refunded"
    assert refunded.refunded_amount_cents == 4_900
  end

  test "foreign host cannot refund" do
    %{payment: payment} = paid_payment()
    assert {:error, :not_authorized} = Refunds.issue_refund(payment.id, insert(:user).id, 4_900)
    assert BookingPaymentQueries.get(payment.id).status == "paid"
  end

  defp paid_payment do
    host = insert(:user)
    meeting = insert(:meeting, organizer_user_id: host.id, status: "completed")

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: host.id,
        stripe_account_id: "acct_HOST",
        stripe_charge_id: "ch_DEFERRED",
        status: "paid",
        paid_at: DateTime.utc_now(:second),
        amount_cents: 4_900,
        currency: "usd"
      )

    %{host: host, payment: payment}
  end
end
