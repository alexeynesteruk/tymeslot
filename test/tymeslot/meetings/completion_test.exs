defmodule Tymeslot.Meetings.CompletionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database

  alias Tymeslot.Meetings.Completion
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingPayments.BookingPaymentAudits

  @snapshot %{
    "service_id" => "online-consultation",
    "service_name" => "Online behavior consultation",
    "amount_cents" => 14_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  test "only the host completes a confirmed direct-service meeting" do
    host = insert(:user)
    meeting = direct_meeting(host, status: "confirmed")

    assert {:ok, completed} = Completion.complete(meeting.id, host.id)
    assert completed.status == "completed"
    assert {:ok, %{status: "completed"}} = MeetingQueries.get_meeting(meeting.id)
  end

  test "completion writes an owner audit when the direct booking has a payment" do
    host = insert(:user)
    meeting = direct_meeting(host)

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: host.id,
        payment_timing: "deferred",
        service_snapshot: @snapshot,
        amount_cents: 14_000,
        currency: "usd",
        status: "card_saved"
      )

    assert {:ok, _completed} = Completion.complete(meeting.id, host.id)

    assert [%{action: "meeting_completed", actor_user_id: actor_id}] =
             BookingPaymentAudits.list_for_payment(payment.id)

    assert actor_id == host.id
  end

  test "an attendee cannot complete the meeting" do
    host = insert(:user)
    attendee = insert(:user)
    meeting = direct_meeting(host, attendee_email: attendee.email)

    assert {:error, :not_authorized} = Completion.complete(meeting.id, attendee.id)
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
  end

  test "a foreign host cannot complete the meeting" do
    host = insert(:user)
    foreign_host = insert(:user)
    meeting = direct_meeting(host)

    assert {:error, :not_authorized} = Completion.complete(meeting.id, foreign_host.id)
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
  end

  test "a cancelled meeting cannot be completed" do
    host = insert(:user)
    meeting = direct_meeting(host, status: "cancelled")

    assert {:error, :invalid_state} = Completion.complete(meeting.id, host.id)
    assert {:ok, %{status: "cancelled"}} = MeetingQueries.get_meeting(meeting.id)
  end

  test "completion cannot be repeated" do
    host = insert(:user)
    meeting = direct_meeting(host)

    assert {:ok, _completed} = Completion.complete(meeting.id, host.id)
    assert {:error, :invalid_state} = Completion.complete(meeting.id, host.id)
  end

  test "a generic meeting cannot use the direct-service completion transition" do
    host = insert(:user)
    meeting = insert(:meeting, organizer_user_id: host.id, service_snapshot: %{})

    assert {:error, :not_direct_service} = Completion.complete(meeting.id, host.id)
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
  end

  defp direct_meeting(host, attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: host.id,
          status: "confirmed",
          service_snapshot: @snapshot
        ],
        attrs
      )
    )
  end
end
