defmodule Tymeslot.Contracts.MyPawTrainerWebsiteContractTest do
  use ExUnit.Case, async: true

  alias Tymeslot.MyPawTrainer.EventRoutes
  alias Tymeslot.MyPawTrainer.Intake
  alias Tymeslot.MyPawTrainer.ServiceCatalog

  @website_facing_catalog [
    %{
      id: "discovery-call",
      price_cents: 4_900,
      duration_minutes: 30,
      scheduler_path: "/anna/discovery-call"
    },
    %{
      id: "online-consultation",
      price_cents: 14_000,
      duration_minutes: 90,
      scheduler_path: "/anna/online-consultation"
    },
    %{
      id: "in-home-consultation",
      price_cents: 19_000,
      duration_minutes: 90,
      scheduler_path: "/anna/in-home-consultation"
    }
  ]

  test "website-facing catalog agrees with scheduler prices, durations, and stable paths" do
    actual =
      Enum.map(@website_facing_catalog, fn expected ->
        service = ServiceCatalog.fetch!(expected.id)
        assert {:ok, path} = EventRoutes.path(expected.id)

        %{
          id: service.id,
          price_cents: service.initial_price_cents,
          duration_minutes: service.duration_minutes,
          scheduler_path: path
        }
      end)

    assert actual == @website_facing_catalog
  end

  test "legacy prices and forbidden booking fields are absent" do
    direct_services = Enum.map(@website_facing_catalog, &ServiceCatalog.fetch!(&1.id))

    refute Enum.any?(direct_services, &(&1.initial_price_cents in [0, 12_000]))

    for service <- direct_services do
      field_ids = Enum.map(Intake.snapshot_for(service.id), & &1["id"])
      refute Enum.any?(field_ids, &(&1 in ~w(phone meeting_mode meeting-mode service_mode)))
    end
  end

  test "approval-first services expose no scheduler event route" do
    for {id, price_cents} <- [
          {"online-case-management", 54_000},
          {"in-person-case-management", 69_000},
          {"assistant-dog-visit", 35_000}
        ] do
      service = ServiceCatalog.fetch!(id)
      assert service.initial_price_cents == price_cents
      refute service.direct_bookable
      assert is_nil(service.route)
      assert {:error, :approval_first} = EventRoutes.path(id)
    end
  end

  test "website-facing fixtures contain catalog data only" do
    fixture = inspect(@website_facing_catalog) |> String.downcase()

    for forbidden <- ~w(client attendee email dog telegram chat_id phone) do
      refute fixture =~ forbidden
    end
  end
end
