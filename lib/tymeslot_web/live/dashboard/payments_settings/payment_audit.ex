defmodule TymeslotWeb.Dashboard.PaymentsSettings.PaymentAudit do
  @moduledoc "Sanitized operational payment history."

  use TymeslotWeb, :html

  attr :audits, :list, default: []

  def payment_audit(assigns) do
    ~H"""
    <ol id="payment-audit">
      <li :for={audit <- @audits}>
        <span>{audit.action}</span>
        <span>{audit.result}</span>
        <span>{format_amount(audit.amount_cents)}</span>
        <span>Attempt {audit.attempt}</span>
        <time datetime={DateTime.to_iso8601(audit.occurred_at)}>
          {Calendar.strftime(audit.occurred_at, "%Y-%m-%d %H:%M UTC")}
        </time>
        <code :if={audit.stripe_object_id}>{sanitize_reference(audit.stripe_object_id)}</code>
      </li>
    </ol>
    """
  end

  defp format_amount(cents) when is_integer(cents),
    do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp format_amount(_cents), do: ""

  defp sanitize_reference(reference) when byte_size(reference) > 7 do
    prefix = reference |> String.split("_", parts: 2) |> hd()
    prefix <> "_..." <> String.slice(reference, -4, 4)
  end

  defp sanitize_reference(_reference), do: "Stripe reference"
end
