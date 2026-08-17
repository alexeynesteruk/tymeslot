defmodule Tymeslot.MeetingPayments.PaymentTiming do
  @moduledoc """
  Payment timing for a bookable event type.

  `upfront` is the existing Tymeslot Checkout charge-now path.
  `deferred` saves a card through Stripe setup mode and charges later.
  """

  @timings ~w(upfront deferred)

  @spec valid?(term()) :: boolean()
  def valid?(timing) when timing in @timings, do: true
  def valid?(_timing), do: false

  @spec deferred?(term()) :: boolean()
  def deferred?("deferred"), do: true
  def deferred?(_timing), do: false

  @spec timings() :: [String.t()]
  def timings, do: @timings

  @spec validate_deferred(map()) ::
          {:ok, String.t()}
          | {:error,
             :missing_service_snapshot
             | :missing_stripe_account
             | :missing_amount
             | :missing_currency}
  def validate_deferred(attrs) when is_map(attrs) do
    cond do
      not snapshot?(Map.get(attrs, :service_snapshot) || Map.get(attrs, "service_snapshot")) ->
        {:error, :missing_service_snapshot}

      blank?(Map.get(attrs, :stripe_account_id) || Map.get(attrs, "stripe_account_id")) ->
        {:error, :missing_stripe_account}

      not positive_int?(Map.get(attrs, :amount_cents) || Map.get(attrs, "amount_cents")) ->
        {:error, :missing_amount}

      blank?(Map.get(attrs, :currency) || Map.get(attrs, "currency")) ->
        {:error, :missing_currency}

      true ->
        {:ok, "deferred"}
    end
  end

  def validate_deferred(_attrs), do: {:error, :missing_service_snapshot}

  defp snapshot?(snapshot) when is_map(snapshot) and map_size(snapshot) > 0, do: true
  defp snapshot?(_snapshot), do: false

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false

  defp positive_int?(value) when is_integer(value) and value > 0, do: true
  defp positive_int?(_value), do: false
end
