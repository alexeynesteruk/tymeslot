defmodule Tymeslot.MyPawTrainer.BookingGuardTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.BookingGuard
  alias Tymeslot.MyPawTrainer.Service
  alias Tymeslot.MyPawTrainer.ZipAllowlist

  test "direct services expose catalog duration and delivery" do
    assert BookingGuard.service("discovery-call").duration_minutes == 30
    assert BookingGuard.service("online-consultation").duration_minutes == 90
    assert %Service{delivery_mode: "in_home"} = BookingGuard.service("in-home-consultation")
  end

  test "approval-first and unknown services are not bookable" do
    assert {:error, :service_not_bookable} =
             BookingGuard.authorize_service("online-case-management", %{})

    assert {:error, :service_not_bookable} =
             BookingGuard.authorize_service("in-person-case-management", %{})

    assert {:error, :service_not_bookable} =
             BookingGuard.authorize_service("assistant-dog-visit", %{})

    assert {:error, :service_not_bookable} = BookingGuard.authorize_service("unknown", %{})
  end

  test "authorize_service rejects a duration that does not match the catalog" do
    assert {:error, :invalid_duration} =
             BookingGuard.authorize_service("discovery-call", %{duration_minutes: 90})

    assert {:error, :invalid_duration} =
             BookingGuard.authorize_service("online-consultation", %{duration_minutes: 30})
  end

  test "authorize_service returns a versioned snapshot for a direct service" do
    assert {:ok, snapshot} =
             BookingGuard.authorize_service("discovery-call", %{duration_minutes: 30})

    assert snapshot["service_id"] == "discovery-call"
    assert snapshot["duration_minutes"] == 30
    assert snapshot["delivery_mode"] == "virtual"
    assert snapshot["amount_cents"] == 4_900
    assert snapshot["currency"] == "usd"
    assert snapshot["event_type_version"] == 1
  end

  test "in-home booking requires an active owner ZIP" do
    owner = insert(:user)

    assert {:error, :service_area_unavailable} =
             BookingGuard.authorize_service("in-home-consultation", %{
               owner_id: owner.id,
               zip: "32084",
               duration_minutes: 90
             })

    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    assert {:ok, snapshot} =
             BookingGuard.authorize_service("in-home-consultation", %{
               owner_id: owner.id,
               zip: "32084",
               duration_minutes: 90
             })

    assert snapshot["service_id"] == "in-home-consultation"
    assert snapshot["delivery_mode"] == "in_home"

    assert {:error, :service_area_unavailable} =
             BookingGuard.authorize_service("in-home-consultation", %{
               owner_id: owner.id,
               zip: "99999",
               duration_minutes: 90
             })
  end

  test "discovery and online never consult the ZIP allowlist" do
    owner = insert(:user)

    assert {:ok, _} =
             BookingGuard.authorize_service("discovery-call", %{
               owner_id: owner.id,
               zip: "99999",
               duration_minutes: 30
             })

    assert {:ok, _} =
             BookingGuard.authorize_service("online-consultation", %{
               owner_id: owner.id,
               duration_minutes: 90
             })
  end
end
