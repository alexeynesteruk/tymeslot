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
    assert Enum.all?(provisioned, &(&1.user_id == owner.id and not &1.is_active))

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
    assert Enum.all?(second, &(not &1.is_active))
    assert length(MeetingTypeQueries.list_all_meeting_types(owner.id)) == 3
  end

  test "reuses an existing valid inactive direct service without modifying it" do
    owner = insert(:user)
    service = ServiceCatalog.fetch!("discovery-call")

    existing =
      insert(:meeting_type,
        user: owner,
        name: service.name,
        description: "Preserve this description",
        duration_minutes: service.duration_minutes,
        icon: "hero-bolt",
        is_active: false,
        is_private: true,
        slug: "preserve-this-slug",
        service_id: service.id,
        service_price_cents: service.initial_price_cents,
        service_currency: "usd",
        event_type_version: 1
      )

    assert {:ok, provisioned} = Provisioning.provision_direct_services(owner.id)
    assert Enum.find(provisioned, &(&1.service_id == service.id)).id == existing.id

    persisted = MeetingTypeQueries.get_meeting_type(existing.id, owner.id)
    refute persisted.is_active
    assert persisted.description == existing.description
    assert persisted.icon == existing.icon
    assert persisted.is_private == existing.is_private
    assert persisted.slug == existing.slug
    assert persisted.updated_at == existing.updated_at
  end

  test "fails closed when an existing direct service is active" do
    owner = insert(:user)

    insert(:meeting_type,
      user: owner,
      name: "Discovery call",
      description: "Discovery call",
      duration_minutes: 30,
      is_active: true,
      service_id: "discovery-call",
      service_price_cents: 4_900,
      service_currency: "usd",
      event_type_version: 1
    )

    assert {:error, :active_existing_service} =
             Provisioning.provision_direct_services(owner.id)
  end

  test "rolls back earlier direct services when a later existing service is active" do
    owner = insert(:user)
    service = ServiceCatalog.fetch!("online-consultation")

    active =
      insert(:meeting_type,
        user: owner,
        name: service.name,
        description: service.name,
        duration_minutes: service.duration_minutes,
        is_active: true,
        service_id: service.id,
        service_price_cents: service.initial_price_cents,
        service_currency: "usd",
        event_type_version: 1
      )

    assert {:error, :active_existing_service} =
             Provisioning.provision_direct_services(owner.id)

    assert [%{id: id, service_id: service_id, is_active: true}] =
             MeetingTypeQueries.list_all_meeting_types(owner.id)

    assert id == active.id
    assert service_id == service.id
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
      is_active: false,
      service_id: "online-consultation",
      service_price_cents: 15_000,
      service_currency: "usd",
      event_type_version: 1
    )

    assert {:error, :invalid_existing_service_configuration} =
             Provisioning.provision_direct_services(owner.id)
  end
end
