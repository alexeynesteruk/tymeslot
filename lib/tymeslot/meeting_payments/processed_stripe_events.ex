defmodule Tymeslot.MeetingPayments.ProcessedStripeEvents do
  @moduledoc """
  Claims Stripe events so webhook handlers stay replay-safe.
  """

  import Ecto.Query

  alias Tymeslot.MeetingPayments.ProcessedStripeEventSchema
  alias Tymeslot.Repo

  @stale_after_seconds 5 * 60

  @spec claim(String.t(), String.t()) ::
          {:ok, :claimed | :duplicate} | {:error, term()}
  def claim(stripe_event_id, event_type)
      when is_binary(stripe_event_id) and is_binary(event_type) do
    attrs = %{
      stripe_event_id: stripe_event_id,
      event_type: event_type,
      status: "processing",
      attempt_count: 1
    }

    case attrs |> ProcessedStripeEventSchema.create_changeset() |> Repo.insert() do
      {:ok, _event} ->
        {:ok, :claimed}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if unique_event_conflict?(errors) do
          reclaim_or_acknowledge(stripe_event_id)
        else
          {:error, :invalid_event}
        end
    end
  end

  def claim(_stripe_event_id, _event_type), do: {:error, :invalid_event}

  @spec complete(String.t()) :: :ok | {:error, :not_found}
  def complete(stripe_event_id) when is_binary(stripe_event_id) do
    now = DateTime.utc_now(:second)

    query =
      from e in ProcessedStripeEventSchema,
        where: e.stripe_event_id == ^stripe_event_id

    case Repo.update_all(query,
           set: [status: "completed", processed_at: now, updated_at: now, error: nil]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @spec fail(String.t(), String.t()) :: :ok | {:error, :not_found}
  def fail(stripe_event_id, error) when is_binary(stripe_event_id) do
    now = DateTime.utc_now(:second)

    query =
      from e in ProcessedStripeEventSchema,
        where: e.stripe_event_id == ^stripe_event_id

    case Repo.update_all(query, set: [status: "failed", error: error, updated_at: now]) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp reclaim_or_acknowledge(stripe_event_id) do
    now = DateTime.utc_now(:second)
    stale_before = DateTime.add(now, -@stale_after_seconds, :second)

    Repo.transaction(fn ->
      query =
        from e in ProcessedStripeEventSchema,
          where: e.stripe_event_id == ^stripe_event_id,
          lock: "FOR UPDATE"

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %{status: "completed"} ->
          :duplicate

        %{status: "processing", updated_at: updated_at} = event ->
          if DateTime.compare(updated_at, stale_before) == :lt do
            event
            |> ProcessedStripeEventSchema.update_changeset(%{
              attempt_count: event.attempt_count + 1,
              error: nil
            })
            |> Repo.update!()

            :claimed
          else
            :duplicate
          end

        %{status: "failed"} = event ->
          event
          |> ProcessedStripeEventSchema.update_changeset(%{
            status: "processing",
            attempt_count: event.attempt_count + 1,
            error: nil
          })
          |> Repo.update!()

          :claimed
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_event_conflict?(errors) do
    match?([{:stripe_event_id, {_, [constraint: :unique, constraint_name: _]}}], errors) or
      Keyword.has_key?(errors, :stripe_event_id)
  end
end
