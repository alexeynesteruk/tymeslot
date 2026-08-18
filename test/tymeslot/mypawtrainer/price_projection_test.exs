defmodule Tymeslot.MyPawTrainer.PriceProjectionTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MyPawTrainer.PriceProjection
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema

  test "publishes a future direct-service price and allowlisted event atomically" do
    owner = insert(:user)
    event_type = direct_event_type(owner)

    assert {:ok, updated, event} =
             PriceProjection.publish(event_type.id, owner.id, 1, 15_000, "usd")

    assert updated.service_price_cents == 15_000
    assert updated.event_type_version == 2
    assert event.event_type == "service.price_published.v1"
    assert event.aggregate_id == Integer.to_string(event_type.id)
    assert event.aggregate_version == 2

    assert MapSet.new(Map.keys(event.payload)) ==
             MapSet.new(
               ~w(event_id service_id cents currency event_type_version aggregate_version occurred_at schema_version)
             )

    assert event.payload["event_id"] == event.event_id
    assert event.payload["service_id"] == "online-consultation"
    assert event.payload["cents"] == 15_000
    assert event.payload["currency"] == "usd"
    assert event.payload["event_type_version"] == 2
    assert event.payload["aggregate_version"] == 2
    assert event.payload["schema_version"] == 1
  end

  test "rejects stale versions, non-usd currency, non-positive cents, and approval-only IDs" do
    owner = insert(:user)
    event_type = direct_event_type(owner)

    assert {:error, :stale_version} =
             PriceProjection.publish(event_type.id, owner.id, 2, 15_000, "usd")

    assert {:error, :invalid_currency} =
             PriceProjection.publish(event_type.id, owner.id, 1, 15_000, "eur")

    assert {:error, :invalid_price} =
             PriceProjection.publish(event_type.id, owner.id, 1, 0, "usd")

    approval =
      insert(:meeting_type,
        user: owner,
        service_id: "online-case-management",
        service_price_cents: 54_000,
        service_currency: "usd",
        event_type_version: 1
      )

    assert {:error, :not_direct_service} =
             PriceProjection.publish(approval.id, owner.id, 1, 55_000, "usd")

    assert Repo.reload(event_type).service_price_cents == 14_000
    refute Repo.exists?(ProjectionOutboxSchema)
  end

  test "an outer rollback removes both the future price and outbox event" do
    owner = insert(:user)
    event_type = direct_event_type(owner)

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, _updated, _event} =
                        PriceProjection.publish(event_type.id, owner.id, 1, 15_000, "usd")

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.reload(event_type).service_price_cents == 14_000
    assert Repo.reload(event_type).event_type_version == 1
    refute Repo.exists?(ProjectionOutboxSchema)
  end

  test "existing meeting snapshots do not change when a future price is published" do
    owner = insert(:user)
    event_type = direct_event_type(owner)
    start_time = DateTime.utc_now(:second) |> DateTime.add(2, :day)

    attrs = %{
      uid: Ecto.UUID.generate(),
      title: "Online behavior consultation",
      summary: "Online behavior consultation",
      description: "",
      start_time: start_time,
      end_time: DateTime.add(start_time, 90, :minute),
      duration: 90,
      organizer_user_id: owner.id,
      organizer_name: "Anna",
      organizer_email: "anna@example.com",
      attendee_name: "Client",
      attendee_email: "client@example.com",
      attendee_timezone: "America/New_York",
      attendee_locale: "en",
      meeting_type_id: event_type.id,
      status: "confirmed"
    }

    assert {:ok, meeting} = Scheduling.create_meeting_with_conflict_check(attrs)
    snapshot = meeting.service_snapshot
    assert snapshot["amount_cents"] == 14_000

    payment =
      insert(:booking_payment,
        host_user_id: owner.id,
        meeting: meeting,
        amount_cents: 14_000,
        currency: "usd",
        payment_timing: "deferred",
        status: "card_saved",
        stripe_customer_id: "cus_snapshot",
        stripe_payment_method_id: "pm_snapshot",
        service_snapshot: snapshot
      )

    assert {:ok, _updated, _event} =
             PriceProjection.publish(event_type.id, owner.id, 1, 15_000, "usd")

    assert Repo.reload(meeting).service_snapshot == snapshot
    assert Repo.reload(payment).service_snapshot == snapshot
    assert Repo.reload(payment).amount_cents == 14_000
  end

  defp direct_event_type(owner) do
    insert(:meeting_type,
      user: owner,
      name: "Online behavior consultation",
      duration_minutes: 90,
      slug: "online-consultation",
      service_id: "online-consultation",
      service_price_cents: 14_000,
      service_currency: "usd",
      event_type_version: 1
    )
  end
end
