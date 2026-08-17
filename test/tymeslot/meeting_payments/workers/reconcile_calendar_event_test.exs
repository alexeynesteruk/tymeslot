defmodule Tymeslot.MeetingPayments.Workers.ReconcileCalendarEventTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.Workers.ReconcileCalendarEvent
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

  @snapshot %{
    "service_id" => "online-consultation",
    "amount_cents" => 14_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  setup :verify_on_exit!
  setup :set_mox_from_context

  describe "perform/1" do
    test "does not create a second event when the provider mapping already exists" do
      {meeting, payment} = insert_confirmed_booking(provider_event_id: "gcal_EXISTING")

      assert :ok =
               perform_job(ReconcileCalendarEvent, %{
                 "meeting_id" => meeting.id,
                 "idempotency_key" => "calendar-create:#{meeting.id}"
               })

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "confirmed"
      assert reloaded.provider_event_id == "gcal_EXISTING"
      assert Repo.reload!(payment).status == "card_saved"
      assert is_nil(Repo.reload!(payment).stripe_charge_id)
    end

    test "does not create a duplicate when Google already has the event" do
      {meeting, payment} = insert_confirmed_booking(provider_event_id: nil)

      expect(Tymeslot.CalendarMock, :get_event, fn uid, user_id ->
        assert uid == meeting.uid
        assert user_id == meeting.organizer_user_id
        {:ok, %{id: "gcal_LOOKUP", uid: uid}}
      end)

      assert :ok =
               perform_job(ReconcileCalendarEvent, %{
                 "meeting_id" => meeting.id,
                 "idempotency_key" => "calendar-create:#{meeting.id}"
               })

      assert Repo.reload!(payment).status == "card_saved"
      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
    end

    test "retries a definite create failure and leaves the booking confirmed" do
      {meeting, payment} = insert_confirmed_booking(provider_event_id: nil)

      stub(Tymeslot.CalendarMock, :get_event, fn _uid, _user_id -> {:error, :not_found} end)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} =
               perform_job(
                 ReconcileCalendarEvent,
                 %{
                   "meeting_id" => meeting.id,
                   "idempotency_key" => "calendar-create:#{meeting.id}"
                 },
                 attempt: 1
               )

      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
      assert Repo.reload!(payment).status == "card_saved"
      assert is_nil(Repo.reload!(payment).stripe_charge_id)
    end

    test "records a terminal operator-visible failure after bounded retries" do
      {meeting, payment} = insert_confirmed_booking(provider_event_id: nil)

      stub(Tymeslot.CalendarMock, :get_event, fn _uid, _user_id -> {:error, :not_found} end)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:error, :unauthorized}
      end)

      assert {:cancel, _reason} =
               perform_job(
                 ReconcileCalendarEvent,
                 %{
                   "meeting_id" => meeting.id,
                   "idempotency_key" => "calendar-create:#{meeting.id}"
                 },
                 attempt: 5
               )

      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
      assert Repo.reload!(payment).status == "card_saved"

      audits = BookingPaymentAudits.list_for_payment(payment.id)
      assert Enum.any?(audits, &(&1.action == "calendar_reconcile" and &1.result == "failed"))
    end
  end

  defp insert_confirmed_booking(opts) do
    user = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "confirmed",
        service_snapshot: @snapshot,
        provider_event_id: Keyword.get(opts, :provider_event_id)
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        stripe_account_id: "acct_HOST",
        status: "card_saved",
        payment_timing: "deferred",
        service_snapshot: @snapshot,
        amount_cents: 14_000,
        currency: "usd"
      )

    {meeting, payment}
  end
end
