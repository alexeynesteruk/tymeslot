defmodule Tymeslot.MyPawTrainer.Workers.ReconcileCrmProjectionsTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.MyPawTrainer.Workers.ReconcileCrmProjections

  test "re-enqueues only a missing or stale booking projection" do
    meeting =
      insert(:meeting,
        service_snapshot: %{
          "service_id" => "online-consultation",
          "service_name" => "Online behavior consultation",
          "delivery_mode" => "virtual"
        }
      )

    {:ok, {:ok, event}} = Repo.transaction(fn -> CrmProjection.append(meeting, "confirmed") end)

    Repo.update!(
      Ecto.Changeset.change(event, state: "delivered", delivered_at: DateTime.utc_now(:second))
    )

    Repo.update!(Ecto.Changeset.change(meeting, status: "completed"))

    assert :ok = ReconcileCrmProjections.perform(%Oban.Job{args: %{}})

    events = Repo.all(ProjectionOutboxSchema)

    assert Enum.map(events, & &1.event_type) |> Enum.sort() == [
             "booking.completed.v1",
             "booking.confirmed.v1"
           ]

    completed = Enum.find(events, &(&1.event_type == "booking.completed.v1"))
    assert completed.aggregate_version == 2
    assert completed.payload["booking_state"] == "completed"
  end

  test "does not emit client, dog, payment, follow-up, case, task, or note events" do
    insert(:meeting, status: "confirmed", service_snapshot: %{})
    assert :ok = ReconcileCrmProjections.perform(%Oban.Job{args: %{}})
    refute Repo.exists?(ProjectionOutboxSchema)
  end

  test "does not regress a rescheduled booking to confirmed" do
    meeting =
      insert(:meeting,
        status: "confirmed",
        service_snapshot: %{
          "service_id" => "online-consultation",
          "service_name" => "Online behavior consultation",
          "delivery_mode" => "virtual"
        }
      )

    {:ok, {:ok, event}} =
      Repo.transaction(fn -> CrmProjection.append(meeting, "rescheduled") end)

    Repo.update!(
      Ecto.Changeset.change(event,
        state: "delivered",
        delivered_at: DateTime.utc_now(:second)
      )
    )

    assert :ok = ReconcileCrmProjections.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(ProjectionOutboxSchema, :count) == 1
  end
end
