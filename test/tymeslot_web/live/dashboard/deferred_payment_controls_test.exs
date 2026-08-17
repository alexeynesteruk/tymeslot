defmodule TymeslotWeb.Dashboard.DeferredPaymentControlsTest do
  use TymeslotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Components.Dashboard.Meetings.CompleteMeetingModal
  alias TymeslotWeb.Dashboard.PaymentsSettings.ChargeModal
  alias TymeslotWeb.Dashboard.PaymentsSettings.PaymentAudit

  test "payment detail lookup preloads the appointment for the charge modal" do
    meeting =
      insert(:meeting,
        start_time: ~U[2026-08-20 14:00:00Z],
        end_time: ~U[2026-08-20 14:30:00Z]
      )

    payment = insert(:booking_payment, meeting: meeting)

    loaded = Tymeslot.MeetingPayments.BookingPaymentQueries.get(payment.id)

    assert loaded.meeting.start_time == ~U[2026-08-20 14:00:00Z]
  end

  test "completion modal identifies attendee and appointment" do
    meeting = %Tymeslot.Meetings.MeetingSchema{
      attendee_name: "Client One",
      start_time: ~U[2026-08-20 14:00:00Z]
    }

    html =
      render_component(&CompleteMeetingModal.complete_meeting_modal/1,
        meeting: meeting,
        show: true,
        target: nil
      )

    assert html =~ "Client One"
    assert html =~ "2026-08-20"
    assert html =~ "Mark completed"
  end

  test "charge modal shows immutable details and has no editable amount" do
    payment = %Tymeslot.MeetingPayments.BookingPaymentSchema{
      attendee_name: "Client Two",
      meeting: %Tymeslot.Meetings.MeetingSchema{start_time: ~U[2026-08-20 14:00:00Z]},
      service_snapshot: %{
        "service_name" => "Online behavior consultation",
        "amount_cents" => 14_000,
        "currency" => "usd"
      }
    }

    html =
      render_component(&ChargeModal.charge_modal/1, payment: payment, show: true, target: nil)

    assert html =~ "Client Two"
    assert html =~ "Online behavior consultation"
    assert html =~ "2026-08-20 14:00 UTC"
    assert html =~ "$140.00"
    refute html =~ ~s(name="amount")
  end

  test "audit renders safe operational fields without payment method or intake" do
    audit = %{
      action: "charge_succeeded",
      result: "paid",
      amount_cents: 4_900,
      attempt: 1,
      occurred_at: ~U[2026-08-20 15:00:00Z],
      stripe_object_id: "pi_1234567890"
    }

    html = render_component(&PaymentAudit.payment_audit/1, audits: [audit])
    assert html =~ "charge_succeeded"
    assert html =~ "paid"
    assert html =~ "$49.00"
    assert html =~ "pi_...7890"
    refute html =~ "payment method"
    refute html =~ "intake"
  end
end
