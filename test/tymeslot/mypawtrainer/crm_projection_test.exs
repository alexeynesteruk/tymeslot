defmodule Tymeslot.MyPawTrainer.CrmProjectionTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.Meetings.Completion

  @snapshot %{
    "service_id" => "online-consultation",
    "service_name" => "Online behavior consultation",
    "delivery_mode" => "virtual"
  }

  test "appends only the exact booking projection allowlist in the current transaction" do
    meeting = insert(:meeting, service_snapshot: @snapshot, attendee_timezone: "America/New_York")

    assert {:ok, {:ok, event}} =
             Repo.transaction(fn ->
               CrmProjection.append(meeting, "confirmed",
                 now: ~U[2026-08-17 20:00:00Z],
                 base_url: "https://book.mypawtrainer.com"
               )
             end)

    assert event.event_type == "booking.confirmed.v1"
    assert event.aggregate_type == "booking"
    assert event.aggregate_id == meeting.id

    assert MapSet.new(Map.keys(event.payload)) ==
             MapSet.new(
               ~w(booking_id service_id service_name appointment_start appointment_end time_zone delivery_mode booking_state aggregate_version last_sync_time operator_deep_link)
             )

    assert event.payload["booking_id"] == meeting.id
    assert event.payload["booking_state"] == "confirmed"

    assert event.payload["operator_deep_link"] ==
             "https://book.mypawtrainer.com/dashboard/meetings?booking_id=#{meeting.id}"
  end

  test "rejects unknown projection keys before insertion" do
    meeting = insert(:meeting, service_snapshot: @snapshot)

    assert {:ok, {:error, :invalid_payload}} =
             Repo.transaction(fn ->
               CrmProjection.append(meeting, "confirmed", extra_payload: %{"price" => 14_000})
             end)

    refute Repo.exists?(ProjectionOutboxSchema)
  end

  test "requires a transaction and disables unresolved event families" do
    meeting = insert(:meeting, service_snapshot: @snapshot)

    assert {:error, :transaction_required} = CrmProjection.append(meeting, "confirmed")
    assert {:error, :event_family_disabled} = CrmProjection.append_client(%{})
    assert {:error, :event_family_disabled} = CrmProjection.append_dog(%{})
    assert {:error, :event_family_disabled} = CrmProjection.append_payment(%{})
    assert {:error, :event_family_disabled} = CrmProjection.append_follow_up(%{})
    refute Repo.exists?(ProjectionOutboxSchema)
  end

  test "producer versions are monotonic and duplicate versions are idempotent" do
    meeting = insert(:meeting, service_snapshot: @snapshot)

    {:ok, {first, duplicate, second}} =
      Repo.transaction(fn ->
        {:ok, first} = CrmProjection.append(meeting, "confirmed")
        {:ok, duplicate} = CrmProjection.append(meeting, "confirmed", aggregate_version: 1)
        {:ok, second} = CrmProjection.append(meeting, "rescheduled")
        {first, duplicate, second}
      end)

    assert first.id == duplicate.id
    assert first.aggregate_version == 1
    assert second.aggregate_version == 2
  end

  test "completion commits its outbox event without calling EspoCRM" do
    owner = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user: owner,
        organizer_user_id: owner.id,
        service_snapshot: @snapshot,
        status: "confirmed"
      )

    Application.put_env(:tymeslot, :crm_projection_delivery_enabled, true)

    Application.put_env(
      :tymeslot,
      :crm_projection_http_client,
      Module.concat(__MODULE__, FailingClient)
    )

    on_exit(fn -> Application.delete_env(:tymeslot, :crm_projection_http_client) end)

    assert {:ok, completed} = Completion.complete(meeting.id, owner.id)
    assert completed.status == "completed"

    assert Repo.get_by!(ProjectionOutboxSchema, aggregate_id: meeting.id).event_type ==
             "booking.completed.v1"
  end

  defmodule FailingClient do
    def post(_url, _body, _headers, _options), do: raise("CRM must not be called")
  end
end
