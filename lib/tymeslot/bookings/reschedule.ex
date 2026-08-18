defmodule Tymeslot.Bookings.Reschedule do
  @moduledoc """
  Orchestrates the booking rescheduling process.
  Handles meeting time updates, calendar event migration, and notifications.
  """

  require Logger

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarJobs, Errors, ManagementTokens, Policy, Validation}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MyPawTrainer.CalendarAvailability
  alias Tymeslot.MyPawTrainer.BookingGuard
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc "Parameters for rescheduling a meeting to a new time slot."
  @type reschedule_params :: %{
          required(:date) => String.t(),
          required(:time) => String.t(),
          required(:duration) => integer() | String.t(),
          required(:user_timezone) => String.t()
        }

  @doc """
  Reschedules an existing meeting.

  This includes:
  1. Validating the new time
  2. Cancelling the original calendar event
  3. Updating meeting times with conflict checking
  4. Creating new calendar event
  5. Sending rescheduling notifications

  The `organizer_user_id` is required. The meeting lookup is scoped to that
  owner, preventing IDOR attacks from the public booking flow.

  Returns `{:ok, meeting}` or `{:error, reason}`, where `reason` is either a
  semantic atom (`Tymeslot.Bookings.Errors.classified_error/0` — currently
  `:meeting_not_found` when the lookup fails, `:slot_taken` when a
  concurrent booking claims the new time first, or `:failed_to_update_meeting`
  when persisting the new time fails for any other reason) or an arbitrary
  policy/validation string from `Tymeslot.Bookings.Policy` or
  `Tymeslot.Bookings.Validation`.
  """
  @spec execute(String.t(), reschedule_params(), any(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, Errors.classified_error() | String.t()}
  def execute(meeting_uid, new_params, _form_data, organizer_user_id)
      when is_binary(meeting_uid) and is_integer(organizer_user_id) do
    with {:ok, original_meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id),
         :ok <- reject_legacy_direct_service(original_meeting),
         :ok <- validate_can_reschedule(original_meeting),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting),
         :ok <- verify_fresh_availability(original_meeting, new_times),
         {:ok, updated_meeting} <- apply_time_update_and_schedule_job(original_meeting, new_times) do
      AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
      sync_provider_video_room(updated_meeting)
      send_reschedule_notifications(updated_meeting, original_meeting)
      {:ok, updated_meeting}
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      {:error, :slot_unavailable} -> {:error, :slot_taken}
      {:error, :calendar_unverifiable} -> {:error, :slot_taken}
      error -> error
    end
  end

  @doc "Reschedules a My Paw Trainer direct booking using its private attendee token."
  @spec execute_with_management_token(String.t(), reschedule_params(), any()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | String.t()}
  def execute_with_management_token(raw_token, new_params, _form_data)
      when is_binary(raw_token) do
    with {:ok, original_meeting, _token} <- ManagementTokens.resolve(raw_token),
         :ok <- authorize_direct_reschedule(original_meeting),
         :ok <- validate_can_reschedule(original_meeting),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting),
         :ok <- verify_fresh_availability(original_meeting, new_times),
         {:ok, updated_meeting, _replacement_raw} <-
           apply_token_time_update(original_meeting, new_times, raw_token) do
      AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
      sync_provider_video_room(updated_meeting)
      send_reschedule_notifications(updated_meeting, original_meeting)
      {:ok, %{updated_meeting | reschedule_url: nil, cancel_url: nil}}
    else
      {:error, :slot_unavailable} -> {:error, :slot_taken}
      {:error, :calendar_unverifiable} -> {:error, :slot_taken}
      {:error, :invalid_management_link} -> {:error, :invalid_management_link}
      error -> error
    end
  end

  # Private functions

  defp apply_time_update_and_schedule_job(meeting, %{
         start_time: start_dt,
         end_time: end_dt,
         duration_minutes: _dur
       }) do
    # Booking a new time settles any pending organizer reschedule request, so
    # the slot becomes live again — clear the timestamp. `status` is left
    # untouched: it tracks the booking lifecycle (pending, awaiting_payment,
    # confirmed, ...), which a reschedule never changes.
    #
    # Reminder sent-tracking is reset too: the reminder(s) already sent were
    # pinned to the old time, so they must not suppress the re-pinned
    # reminder jobs scheduled for the new time.
    attrs = %{
      start_time: start_dt,
      end_time: end_dt,
      reschedule_requested_at: nil,
      reminders_sent: [],
      reminder_email_sent: false
    }

    case Repo.transaction(fn ->
           with {:ok, updated} <- update_meeting(meeting, attrs),
                {:ok, _result} <- schedule_calendar_job(updated),
                :ok <- CrmProjection.append_transition(updated, "rescheduled") do
             updated
           else
             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, updated} -> {:ok, updated}
      {:error, :slot_taken} -> {:error, :slot_taken}
      {:error, :booking_limit_reached} -> {:error, :booking_limit_reached}
      {:error, :failed_to_update_meeting} -> {:error, :failed_to_update_meeting}
      {:error, _reason} -> {:error, :failed_to_update_meeting}
    end
  end

  defp apply_token_time_update(meeting, new_times, raw_token) do
    attrs = %{
      start_time: new_times.start_time,
      end_time: new_times.end_time,
      reschedule_requested_at: nil,
      reminders_sent: [],
      reminder_email_sent: false,
      reschedule_url: nil,
      cancel_url: nil
    }

    Repo.transaction(fn ->
      with {:ok, updated} <- update_meeting(meeting, attrs),
           {:ok, _result} <- schedule_calendar_job(updated),
           {:ok, replacement_raw, _replacement} <-
             ManagementTokens.consume_and_rotate(raw_token, updated),
           :ok <- CrmProjection.append_transition(updated, "rescheduled") do
        {updated, replacement_raw}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {updated, replacement_raw}} ->
        {:ok, %{updated | reschedule_url: management_url(updated, replacement_raw)},
         replacement_raw}

      {:error, :time_conflict} ->
        {:error, :slot_taken}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp management_url(meeting, raw_token) do
    case ProfileQueries.get_by_user_id(meeting.organizer_user_id) do
      {:ok, %{username: username}} when is_binary(username) ->
        ManagementTokens.management_url(username, raw_token)

      _missing_profile ->
        nil
    end
  end

  defp validate_can_reschedule(meeting) do
    Policy.can_reschedule_meeting?(meeting)
  end

  # The rescheduled meeting keeps its meeting type, so the notice and window
  # rules re-checked here come from the same schedule the original booking used.
  defp prepare_new_times(params, meeting) do
    organizer_user_id = meeting.organizer_user_id
    meeting_type = fetch_meeting_type(meeting.meeting_type_id, organizer_user_id)
    duration = reschedule_duration(meeting, meeting_type, params)

    with {:ok, {start_datetime, end_datetime}} <-
           Validation.parse_meeting_times(
             params.date,
             params.time,
             duration,
             params.user_timezone
           ),
         :ok <-
           Validation.validate_booking_time(
             start_datetime,
             params.user_timezone,
             Policy.scheduling_config(organizer_user_id, meeting_type)
           ) do
      {:ok,
       %{
         start_time: start_datetime,
         end_time: end_datetime,
         duration_minutes: duration
       }}
    end
  end

  defp reschedule_duration(meeting, meeting_type, params) do
    cond do
      is_integer(get_in(meeting.service_snapshot, ["duration_minutes"])) ->
        meeting.service_snapshot["duration_minutes"]

      is_integer(meeting.duration) and meeting.duration > 0 ->
        meeting.duration

      match?(%{duration_minutes: mins} when is_integer(mins), meeting_type) ->
        meeting_type.duration_minutes

      true ->
        TimeSlots.parse_duration(params.duration)
    end
  end

  defp verify_fresh_availability(meeting, new_times) do
    if direct_service_meeting?(meeting) do
      meeting_type = fetch_meeting_type(meeting.meeting_type_id, meeting.organizer_user_id)
      config = Policy.scheduling_config(meeting.organizer_user_id, meeting_type)

      CalendarAvailability.final_check(%{
        start_datetime: new_times.start_time,
        end_datetime: new_times.end_time,
        date: DateTime.to_date(new_times.start_time),
        organizer_user_id: meeting.organizer_user_id,
        buffer_minutes: config.buffer_minutes,
        meeting_type: meeting_type
      })
    else
      :ok
    end
  end

  defp direct_service_meeting?(meeting) do
    ServiceCatalog.direct_bookable?(get_in(meeting.service_snapshot, ["service_id"]))
  end

  defp reject_legacy_direct_service(meeting) do
    if direct_service_meeting?(meeting), do: {:error, :invalid_management_link}, else: :ok
  end

  defp authorize_direct_reschedule(meeting) do
    service_id = get_in(meeting.service_snapshot, ["service_id"])

    case BookingGuard.authorize_reschedule(service_id, %{
           owner_id: meeting.organizer_user_id,
           duration_minutes: get_in(meeting.service_snapshot, ["duration_minutes"])
         }) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Ad-hoc meetings carry no meeting type; a nil resolves the organiser's
  # default schedule, which is the right rule set for them.
  defp fetch_meeting_type(nil, _organizer_user_id), do: nil

  defp fetch_meeting_type(meeting_type_id, organizer_user_id),
    do: MeetingTypes.get_meeting_type(meeting_type_id, organizer_user_id)

  defp update_meeting(meeting, attrs) do
    case Scheduling.update_meeting_with_conflict_check(meeting, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, :time_conflict} -> {:error, :slot_taken}
      {:error, :booking_limit_reached} -> {:error, :booking_limit_reached}
      {:error, _reason} -> {:error, :failed_to_update_meeting}
    end
  end

  defp schedule_calendar_job(updated) do
    CalendarJobs.schedule_job(updated, "update")
  end

  # Enqueues a supervised, retrying video-sync job so the provider-side meeting
  # (e.g. Zoom) is updated to match the new booking time. Routed through Oban —
  # not done inline — so a transient Zoom 5xx/429 retries instead of permanently
  # desyncing. Never blocks the reschedule: the booking is already updated
  # locally and the join URL remains valid. Whether an integration can still
  # reach the room is decided inside the job by `IntegrationResolver`, so a
  # meeting whose integration was disconnected is still synced rather than left
  # advertising the old time.
  defp sync_provider_video_room(%{video_room_id: nil}), do: :ok
  defp sync_provider_video_room(%{organizer_user_id: nil}), do: :ok

  defp sync_provider_video_room(meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "update") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue provider video sync on reschedule",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp send_reschedule_notifications(updated_meeting, original_meeting) do
    case Events.meeting_rescheduled(updated_meeting, original_meeting) do
      {:ok, _result} ->
        Logger.info("Reschedule notifications sent", meeting_id: updated_meeting.id)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send reschedule notifications",
          meeting_id: updated_meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end
end
