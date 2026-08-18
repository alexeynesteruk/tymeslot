defmodule Tymeslot.MyPawTrainer.EspoCRMClient do
  @moduledoc "Bounded HTTP transport dedicated to EspoCRM booking projections."

  alias Tymeslot.Infrastructure.HTTPClient

  @callback post(String.t(), binary(), [{String.t(), String.t()}], keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback reconcile(String.t(), binary(), [{String.t(), String.t()}], keyword()) ::
              {:ok, map()} | {:error, term()}

  def post(url, body, headers, options), do: HTTPClient.post(url, body, headers, options)
  def reconcile(url, body, headers, options), do: HTTPClient.post(url, body, headers, options)
end
