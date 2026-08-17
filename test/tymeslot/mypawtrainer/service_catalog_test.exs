defmodule Tymeslot.MyPawTrainer.ServiceCatalogTest do
  use ExUnit.Case, async: true
  alias Tymeslot.MyPawTrainer.{Service, ServiceCatalog}

  test "returns exactly the approved six services in public order" do
    assert Enum.map(ServiceCatalog.all(), & &1.id) ==
             ~w(discovery-call online-consultation in-home-consultation online-case-management in-person-case-management assistant-dog-visit)
  end

  test "direct services have seeded prices, durations, delivery and routes" do
    assert %Service{
             initial_price_cents: 4_900,
             duration_minutes: 30,
             delivery_mode: "virtual",
             direct_bookable: true,
             route: "discovery-call"
           } = ServiceCatalog.fetch!("discovery-call")

    assert %Service{
             initial_price_cents: 14_000,
             duration_minutes: 90,
             delivery_mode: "virtual",
             direct_bookable: true,
             route: "online-consultation"
           } = ServiceCatalog.fetch!("online-consultation")

    assert %Service{
             initial_price_cents: 19_000,
             duration_minutes: 90,
             delivery_mode: "in_home",
             direct_bookable: true,
             route: "in-home-consultation"
           } = ServiceCatalog.fetch!("in-home-consultation")
  end

  test "approval-first services are not directly bookable" do
    refute ServiceCatalog.direct_bookable?("online-case-management")
    refute ServiceCatalog.direct_bookable?("in-person-case-management")
    refute ServiceCatalog.direct_bookable?("assistant-dog-visit")

    assert ServiceCatalog.direct_booking_ids() ==
             ~w(discovery-call online-consultation in-home-consultation)
  end

  test "unknown and malformed service IDs fail closed" do
    assert_raise ArgumentError, fn -> ServiceCatalog.fetch!("unknown") end
    assert {:error, :unknown_service} = ServiceCatalog.validate_id("unknown")
    assert {:error, :invalid_service_id} = ServiceCatalog.validate_id("Online Consultation")
  end

  test "route metadata and snapshots are safe and versioned" do
    service = ServiceCatalog.fetch!("online-consultation")

    assert ServiceCatalog.route_metadata(service) == %{
             id: "online-consultation",
             route: "online-consultation",
             direct_bookable: true,
             cta: "Book an Online Consultation"
           }

    assert ServiceCatalog.snapshot(%{
             service_id: "online-consultation",
             price_cents: 14_000,
             currency: "usd",
             version: 1
           }) == %{
             "service_id" => "online-consultation",
             "service_name" => "Online behavior consultation",
             "amount_cents" => 14_000,
             "currency" => "usd",
             "duration_minutes" => 90,
             "delivery_mode" => "virtual",
             "event_type_version" => 1
           }
  end
end
