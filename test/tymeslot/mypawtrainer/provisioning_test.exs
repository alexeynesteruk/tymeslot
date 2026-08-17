defmodule Tymeslot.MyPawTrainer.ProvisioningTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.{Provisioning, ServiceCatalog}
  alias Tymeslot.MeetingTypes.MeetingTypeQueries

  test "provisions exactly the three direct services for the explicit owner" do
    owner = insert(:user)
    other_owner = insert(:user)
    generic = insert(:meeting_type, user: owner, name: "Generic meeting", duration_minutes: 15)

    assert {:ok, provisioned} = Provisioning.provision_direct_services(owner.id)

    assert Enum.map(provisioned, & &1.service_id) == ServiceCatalog.direct_booking_ids()
    assert Enum.all?(provisioned, &(&1.user_id == owner.id and &1.is_active))

    assert Enum.map(provisioned, &{&1.service_id, &1.service_price_cents, &1.event_type_version}) ==
             [
               {"discovery-call", 4_900, 1},
               {"online-consultation", 14_000, 1},
               {"in-home-consultation", 19_000, 1}
             ]

    assert MeetingTypeQueries.get_meeting_type(generic.id, owner.id).id == generic.id
    assert MeetingTypeQueries.list_all_meeting_types(other_owner.id) == []
  end

  test "is idempotent for an owner and does not duplicate direct services" do
    owner = insert(:user)

    assert {:ok, first} = Provisioning.provision_direct_services(owner.id)
    assert {:ok, second} = Provisioning.provision_direct_services(owner.id)

    assert Enum.map(second, & &1.id) == Enum.map(first, & &1.id)
    assert length(MeetingTypeQueries.list_all_meeting_types(owner.id)) == 3
  end

  test "rejects an invalid owner identifier without writing" do
    assert {:error, :invalid_owner_id} = Provisioning.provision_direct_services("anna")
  end

  test "rejects a missing owner without writing" do
    assert {:error, :owner_not_found} = Provisioning.provision_direct_services(9_999_999)
  end

  test "fails closed when an existing direct service is not the catalog initial configuration" do
    owner = insert(:user)

    insert(:meeting_type,
      user: owner,
      name: "Online behavior consultation",
      duration_minutes: 90,
      service_id: "online-consultation",
      service_price_cents: 15_000,
      service_currency: "usd",
      event_type_version: 1
    )

    assert {:error, :invalid_existing_service_configuration} =
             Provisioning.provision_direct_services(owner.id)
  end
end
