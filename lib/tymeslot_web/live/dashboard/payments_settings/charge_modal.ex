defmodule TymeslotWeb.Dashboard.PaymentsSettings.ChargeModal do
  @moduledoc "Read-only confirmation of an immutable deferred charge."

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS

  attr :payment, :any, default: nil
  attr :show, :boolean, default: false
  attr :target, :any, default: nil

  def charge_modal(assigns) do
    ~H"""
    <.modal
      :if={@show && @payment}
      id="charge-payment-modal"
      show={true}
      on_cancel={JS.push("close_charge_modal", target: @target)}
      size={:small}
    >
      <:header>Charge saved card?</:header>
      <div class="space-y-2 text-tymeslot-700">
        <p class="font-semibold">{@payment.service_snapshot["service_name"]}</p>
        <p>{@payment.attendee_name}</p>
        <p>{format_appointment(@payment.meeting)}</p>
        <p class="font-semibold">{format_amount(@payment.service_snapshot)}</p>
      </div>
      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button variant={:secondary} phx-click="close_charge_modal" phx-target={@target}>
            Cancel
          </.action_button>
          <.action_button
            variant={:primary}
            phx-click="submit_charge"
            phx-value-id={@payment.id}
            phx-target={@target}
          >
            Confirm charge
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp format_amount(%{"amount_cents" => cents, "currency" => "usd"}),
    do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp format_amount(_snapshot), do: ""

  defp format_appointment(%{start_time: %DateTime{} = start_time}),
    do: Calendar.strftime(start_time, "%Y-%m-%d %H:%M UTC")

  defp format_appointment(_meeting), do: ""
end
