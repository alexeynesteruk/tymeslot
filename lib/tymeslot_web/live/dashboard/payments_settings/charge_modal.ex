defmodule TymeslotWeb.Dashboard.PaymentsSettings.ChargeModal do
  @moduledoc "Read-only confirmation of an immutable deferred charge."

  use TymeslotWeb, :html

  attr :payment, :any, default: nil
  attr :show, :boolean, default: false
  attr :target, :any, default: nil

  def charge_modal(assigns) do
    ~H"""
    <div :if={@show && @payment} id="charge-payment-modal" role="dialog" aria-modal="true">
      <h2>Charge saved card?</h2>
      <p>{@payment.service_snapshot["service_name"]}</p>
      <p>{@payment.attendee_name}</p>
      <p>{format_amount(@payment.service_snapshot)}</p>
      <button type="button" phx-click="submit_charge" phx-value-id={@payment.id} phx-target={@target}>
        Confirm charge
      </button>
      <button type="button" phx-click="close_charge_modal" phx-target={@target}>Cancel</button>
    </div>
    """
  end

  defp format_amount(%{"amount_cents" => cents, "currency" => "usd"}),
    do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp format_amount(_snapshot), do: ""
end
