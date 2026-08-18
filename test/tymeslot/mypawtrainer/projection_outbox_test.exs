defmodule Tymeslot.MyPawTrainer.ProjectionOutboxTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.ProjectionOutbox
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema

  @event_type "service.price_published.v1"

  test "appends once inside a transaction for an aggregate event version" do
    attrs = event_attrs()

    assert {:ok, event} =
             Repo.transaction(fn ->
               assert {:ok, first} = ProjectionOutbox.append(attrs)
               assert {:ok, duplicate} = ProjectionOutbox.append(attrs)
               assert first.id == duplicate.id
               first
             end)

    assert event.state == "pending"
    assert Repo.aggregate(ProjectionOutboxSchema, :count) == 1
  end

  test "requires the caller's existing transaction" do
    assert {:error, :transaction_required} = ProjectionOutbox.append(event_attrs())
    refute Repo.exists?(ProjectionOutboxSchema)
  end

  test "claim, retry, delivery, and dead-letter transitions store sanitized codes only" do
    first = insert_event(aggregate_version: 2)
    second = insert_event(aggregate_version: 3)
    now = DateTime.utc_now(:second)

    assert [claimed] = ProjectionOutbox.claim_due(1, now)
    assert claimed.id in [first.id, second.id]
    assert claimed.state == "delivering"
    assert claimed.attempt_count == 1

    retry_at = DateTime.add(now, 60, :second)
    assert {:ok, retried} = ProjectionOutbox.reschedule_retry(claimed.id, "timeout", retry_at)
    assert retried.state == "pending"
    assert retried.error_code == "timeout"
    assert retried.next_attempt_at == retry_at

    assert {:error, :invalid_error_code} =
             ProjectionOutbox.dead_letter(retried.id, "raw response: client@example.com")

    assert {:ok, dead} = ProjectionOutbox.dead_letter(retried.id, "schema_invalid")
    assert dead.state == "dead_letter"
    assert dead.error_code == "schema_invalid"

    remaining_id = if claimed.id == first.id, do: second.id, else: first.id
    assert {:ok, delivering} = ProjectionOutbox.claim_due(1, now) |> Enum.fetch(0)
    assert delivering.id == remaining_id
    assert {:ok, delivered} = ProjectionOutbox.mark_delivered(delivering.id, now)
    assert delivered.state == "delivered"
    assert delivered.delivered_at == now
    assert is_nil(delivered.error_code)
  end

  defp insert_event(overrides) do
    attrs = Map.merge(event_attrs(), Map.new(overrides))
    attrs = put_in(attrs.payload["aggregate_version"], attrs.aggregate_version)
    {:ok, {:ok, event}} = Repo.transaction(fn -> ProjectionOutbox.append(attrs) end)
    event
  end

  defp event_attrs do
    event_id = Ecto.UUID.generate()
    occurred_at = DateTime.utc_now(:second)

    %{
      event_id: event_id,
      event_type: @event_type,
      schema_version: 1,
      aggregate_type: "meeting_type",
      aggregate_id: Ecto.UUID.generate(),
      aggregate_version: 1,
      occurred_at: occurred_at,
      payload: %{
        "event_id" => event_id,
        "service_id" => "online-consultation",
        "cents" => 14_500,
        "currency" => "usd",
        "event_type_version" => 2,
        "aggregate_version" => 1,
        "occurred_at" => DateTime.to_iso8601(occurred_at),
        "schema_version" => 1
      }
    }
  end
end
