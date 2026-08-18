defmodule TymeslotWeb.Components.Dashboard.Meetings.CompleteMeetingModal do
  @moduledoc "Confirmation modal for the explicit meeting-completion action."

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS

  attr :meeting, :any, default: nil
  attr :show, :boolean, default: false
  attr :target, :any, default: nil

  def complete_meeting_modal(assigns) do
    ~H"""
    <.modal
      :if={@show && @meeting}
      id="complete-meeting-modal"
      show={true}
      on_cancel={JS.push("hide_complete_modal", target: @target)}
      size={:small}
    >
      <:header>Mark appointment completed?</:header>
      <div class="space-y-2 text-tymeslot-700">
        <p class="font-semibold">{@meeting.attendee_name}</p>
        <time datetime={DateTime.to_iso8601(@meeting.start_time)}>
          {Calendar.strftime(@meeting.start_time, "%Y-%m-%d %H:%M UTC")}
        </time>
      </div>
      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button variant={:secondary} phx-click="hide_complete_modal" phx-target={@target}>
            Cancel
          </.action_button>
          <.action_button variant={:primary} phx-click="confirm_complete_meeting" phx-target={@target}>
            Mark completed
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
