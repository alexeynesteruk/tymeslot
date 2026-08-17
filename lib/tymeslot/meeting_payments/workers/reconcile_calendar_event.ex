defmodule Tymeslot.MeetingPayments.Workers.ReconcileCalendarEvent do
  @moduledoc """
  Retries Google calendar creation for a confirmed deferred booking.

  The booking and payment stay confirmed. This worker never creates a
  second booking or a charge. It looks up the provider event before
  creating so an uncertain first response cannot duplicate the event.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    unique: [period: 86_400, keys: [:idempotency_key]]

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}, attempt: attempt}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        reconcile(meeting, attempt)

      {:error, :not_found} ->
        {:cancel, :meeting_not_found}
    end
  end

  defp reconcile(meeting, attempt) do
    cond do
      present?(meeting.provider_event_id) ->
        :ok

      existing_provider_event?(meeting) ->
        :ok

      true ->
        apply_create(meeting, attempt)
    end
  end

  defp existing_provider_event?(meeting) do
    case calendar_module().get_event(meeting.uid, meeting.organizer_user_id) do
      {:ok, _event} -> true
      {:error, :not_found} -> false
      {:error, _reason} -> false
    end
  end

  defp calendar_module do
    Application.get_env(:tymeslot, :calendar_module) ||
      Tymeslot.Integrations.Calendar.Events
  end

  defp apply_create(meeting, attempt) do
    case CalendarEventSync.create(meeting.id, attempt) do
      :ok ->
        :ok

      {:discard, reason} ->
        record_terminal(meeting, reason)
        {:cancel, reason}

      {:error, reason} ->
        if attempt >= 5 do
          record_terminal(meeting, reason)
          {:cancel, reason}
        else
          {:error, reason}
        end
    end
  end

  defp record_terminal(meeting, reason) do
    Logger.error("ReconcileCalendarEvent reached a terminal calendar failure",
      meeting_id: meeting.id,
      error_category: error_category(reason)
    )

    case BookingPaymentQueries.by_meeting_id(meeting.id) do
      nil ->
        :ok

      payment ->
        _result =
          BookingPaymentAudits.append(%{
            booking_payment_id: payment.id,
            meeting_id: meeting.id,
            actor_type: "system",
            action: "calendar_reconcile",
            result: "failed",
            detail_code: error_category(reason)
          })

        :ok
    end
  end

  defp present?(id) when is_binary(id), do: byte_size(id) > 0
  defp present?(_id), do: false

  defp error_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_category(_reason), do: "calendar_create_failed"
end
