defmodule Tymeslot.MyPawTrainer.PriceProjection do
  @moduledoc "Publishes future direct-service price changes transactionally."

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MyPawTrainer.ProjectionOutbox
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo

  @event_type "service.price_published.v1"
  @schema_version 1

  @spec publish(integer(), integer(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, Ecto.Schema.t(), Ecto.Schema.t()} | {:error, term()}
  def publish(id, owner_id, expected_version, cents, currency)
      when is_integer(id) and is_integer(owner_id) and is_integer(expected_version) and
             is_integer(cents) and is_binary(currency) do
    Repo.transaction(fn ->
      with {:ok, event_type} <- MeetingTypeQueries.lock_service_price(id, owner_id),
           :ok <- validate(event_type, expected_version, cents, currency),
           {:ok, updated} <-
             MeetingTypeQueries.persist_service_price(event_type, cents, expected_version + 1),
           {:ok, event} <- append_event(updated) do
        {updated, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {updated, event}} -> {:ok, updated, event}
      {:error, reason} -> {:error, reason}
    end
  end

  def publish(_id, _owner_id, _expected_version, _cents, _currency),
    do: {:error, :invalid_request}

  defp validate(event_type, expected_version, cents, currency) do
    cond do
      not ServiceCatalog.direct_bookable?(event_type.service_id) -> {:error, :not_direct_service}
      event_type.service_currency != "usd" or currency != "usd" -> {:error, :invalid_currency}
      event_type.event_type_version != expected_version -> {:error, :stale_version}
      cents <= 0 -> {:error, :invalid_price}
      true -> :ok
    end
  end

  defp append_event(event_type) do
    event_id = Ecto.UUID.generate()
    occurred_at = DateTime.utc_now(:second)
    aggregate_version = event_type.event_type_version

    payload = %{
      "event_id" => event_id,
      "service_id" => event_type.service_id,
      "cents" => event_type.service_price_cents,
      "currency" => event_type.service_currency,
      "event_type_version" => event_type.event_type_version,
      "aggregate_version" => aggregate_version,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "schema_version" => @schema_version
    }

    ProjectionOutbox.append(%{
      event_id: event_id,
      event_type: @event_type,
      schema_version: @schema_version,
      aggregate_type: "meeting_type",
      aggregate_id: Integer.to_string(event_type.id),
      aggregate_version: aggregate_version,
      occurred_at: occurred_at,
      payload: payload
    })
  end
end
