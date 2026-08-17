defmodule TymeslotWeb.Components.Dashboard.Meetings.CompleteMeetingModal do
  @moduledoc "Confirmation modal for the explicit meeting-completion action."

  use TymeslotWeb, :html

  attr :meeting, :any, default: nil
  attr :show, :boolean, default: false
  attr :target, :any, default: nil

  def complete_meeting_modal(assigns) do
    ~H"""
    <div :if={@show && @meeting} id="complete-meeting-modal" role="dialog" aria-modal="true">
      <h2>Mark appointment completed?</h2>
      <p>{@meeting.attendee_name}</p>
      <time datetime={DateTime.to_iso8601(@meeting.start_time)}>
        {Calendar.strftime(@meeting.start_time, "%Y-%m-%d %H:%M UTC")}
      </time>
      <button type="button" phx-click="confirm_complete_meeting" phx-target={@target}>
        Mark completed
      </button>
      <button type="button" phx-click="hide_complete_modal" phx-target={@target}>Cancel</button>
    </div>
    """
  end
end
