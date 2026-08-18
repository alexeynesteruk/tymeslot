defmodule Tymeslot.MyPawTrainer.FollowUpTokens do
  @moduledoc "Generates and hashes unguessable follow-up link tokens."

  def generate, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

  def attendee_hash(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    :crypto.hash(:sha256, normalized)
  end
end
