defmodule Tymeslot.MyPawTrainer.Workers.ReconcileCrmProjections do
  @moduledoc "Re-enqueues missing or stale booking-only CRM projections."

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 300]

  import Ecto.Query

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo

  @states ~w(confirmed completed cancelled expired)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    MeetingSchema
    |> where([meeting], meeting.status in @states)
    |> Repo.all()
    |> Enum.filter(&ServiceCatalog.direct_bookable?(get_in(&1.service_snapshot, ["service_id"])))
    |> Enum.each(&reconcile/1)

    :ok
  end

  defp reconcile(meeting) do
    latest =
      Repo.one(
        from event in ProjectionOutboxSchema,
          where: event.aggregate_type == "booking" and event.aggregate_id == ^meeting.id,
          order_by: [desc: event.aggregate_version],
          limit: 1
      )

    state = projected_state(meeting.status, latest)

    if is_nil(latest) or latest.payload["booking_state"] != state do
      _ = Repo.transaction(fn -> CrmProjection.append(meeting, state) end)
    end
  end

  defp projected_state("confirmed", %{payload: %{"booking_state" => "rescheduled"}}),
    do: "rescheduled"

  defp projected_state(state, _latest), do: state
end
