defmodule Tymeslot.MyPawTrainer.ProjectionHTTPClient do
  @moduledoc "Bounded HTTP transport dedicated to signed price projections."

  alias Tymeslot.Infrastructure.HTTPClient

  @callback post(String.t(), binary(), [{String.t(), String.t()}], keyword()) ::
              {:ok, map()} | {:error, term()}

  @spec post(String.t(), binary(), [{String.t(), String.t()}], keyword()) ::
          {:ok, map()} | {:error, term()}
  def post(url, body, headers, options) do
    HTTPClient.post(url, body, headers, options)
  end
end
