defmodule Tymeslot.MyPawTrainer.EventRoutesTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.EventRoutes

  test "returns one stable scheduler path for every direct service" do
    assert {:ok, "/anna/discovery-call"} = EventRoutes.path("discovery-call")
    assert {:ok, "/anna/online-consultation"} = EventRoutes.path("online-consultation")
    assert {:ok, "/anna/in-home-consultation"} = EventRoutes.path("in-home-consultation")
  end

  test "rejects approval-only and unknown service IDs" do
    for id <- [
          "online-case-management",
          "in-person-case-management",
          "assistant-dog-visit"
        ] do
      assert {:error, :approval_first} = EventRoutes.path(id)
    end

    assert {:error, :unknown_service} = EventRoutes.path("not-a-service")
  end

  test "resolves only an active owner event type on its stable route" do
    owner = insert(:user)

    active =
      insert(:meeting_type,
        user: owner,
        duration_minutes: 30,
        slug: "discovery-call",
        is_active: true,
        service_id: "discovery-call",
        service_price_cents: 4_900,
        service_currency: "usd",
        event_type_version: 1
      )

    inactive =
      insert(:meeting_type,
        user: owner,
        duration_minutes: 90,
        slug: "online-consultation",
        is_active: false,
        service_id: "online-consultation",
        service_price_cents: 14_000,
        service_currency: "usd",
        event_type_version: 1
      )

    active_id = active.id

    assert {:ok, %{path: "/anna/discovery-call", meeting_type_id: ^active_id}} =
             EventRoutes.resolve(owner.id, "discovery-call")

    assert {:error, :unavailable} = EventRoutes.resolve(owner.id, "online-consultation")
    assert {:error, :unavailable} = EventRoutes.resolve(owner.id, "in-home-consultation")
    assert {:error, :approval_first} = EventRoutes.resolve(owner.id, "online-case-management")

    assert Repo.reload(inactive).is_active == false
  end
end
