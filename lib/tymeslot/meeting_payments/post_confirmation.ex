defmodule Tymeslot.MeetingPayments.PostConfirmation do
  @moduledoc """
  Queues calendar creation and confirmation email independently after a
  deferred booking is confirmed. A calendar failure never rolls back the
  booking or creates a charge.
  """

  require Logger

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.Workers.ReconcileCalendarEvent
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.VideoRoomWorker

  @spec enqueue(Tymeslot.Meetings.MeetingSchema.t(), map() | nil) :: :ok
  def enqueue(meeting, payment \\ nil) do
    enqueue_email(meeting)
    enqueue_calendar(meeting, payment)
    :ok
  end

  defp enqueue_email(meeting) do
    if meeting.video_integration_id do
      VideoRoomWorker.schedule_video_room_creation_with_emails(meeting.id)
    else
      _result = Events.meeting_created(meeting)
      :ok
    end
  end

  defp enqueue_calendar(meeting, payment) do
    case CalendarJobs.schedule_job(meeting, "create") do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Deferred confirmation failed to enqueue calendar create",
          meeting_id: meeting.id,
          error_category: :calendar_enqueue_failed
        )

        maybe_audit(payment, meeting, reason)
        enqueue_reconcile(meeting)
    end
  end

  defp maybe_audit(nil, _meeting, _reason), do: :ok

  defp maybe_audit(payment, meeting, _reason) do
    _result =
      BookingPaymentAudits.append(%{
        booking_payment_id: payment.id,
        meeting_id: meeting.id,
        actor_type: "system",
        action: "calendar_create",
        result: "failed",
        detail_code: "calendar_enqueue_failed"
      })

    :ok
  end

  defp enqueue_reconcile(meeting) do
    %{meeting_id: meeting.id, idempotency_key: "calendar-create:#{meeting.id}"}
    |> ReconcileCalendarEvent.new(unique: [period: 86_400, keys: [:idempotency_key]])
    |> Oban.insert()

    :ok
  end
end
