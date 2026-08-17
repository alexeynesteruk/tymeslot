defmodule Tymeslot.MyPawTrainer.ServiceCatalog do
  @moduledoc "Code-owned six-service contract shared with the website."

  alias Tymeslot.MyPawTrainer.Service
  @service_id_format ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @services [
    %Service{
      id: "discovery-call",
      name: "Discovery call",
      duration_minutes: 30,
      delivery_mode: "virtual",
      direct_bookable: true,
      intake_kind: :discovery,
      initial_price_cents: 4_900,
      route: "discovery-call",
      cta: "Book a Discovery Call"
    },
    %Service{
      id: "online-consultation",
      name: "Online behavior consultation",
      duration_minutes: 90,
      delivery_mode: "virtual",
      direct_bookable: true,
      intake_kind: :full,
      initial_price_cents: 14_000,
      route: "online-consultation",
      cta: "Book an Online Consultation"
    },
    %Service{
      id: "in-home-consultation",
      name: "In-home behavior consultation",
      duration_minutes: 90,
      delivery_mode: "in_home",
      direct_bookable: true,
      intake_kind: :full,
      initial_price_cents: 19_000,
      route: "in-home-consultation",
      cta: "Book an In-Home Consultation"
    },
    %Service{
      id: "online-case-management",
      name: "One-month online case management",
      duration_minutes: nil,
      delivery_mode: "virtual",
      direct_bookable: false,
      intake_kind: :approval,
      initial_price_cents: 54_000,
      route: nil,
      cta: "Apply for Case Support"
    },
    %Service{
      id: "in-person-case-management",
      name: "One-month in-person case management",
      duration_minutes: nil,
      delivery_mode: "in_home",
      direct_bookable: false,
      intake_kind: :approval,
      initial_price_cents: 69_000,
      route: nil,
      cta: "Apply for Case Support"
    },
    %Service{
      id: "assistant-dog-visit",
      name: "Assistant-dog visit",
      duration_minutes: nil,
      delivery_mode: "in_home",
      direct_bookable: false,
      intake_kind: :approval,
      initial_price_cents: 35_000,
      route: nil,
      cta: "Ask About an Assistant-Dog Visit"
    }
  ]
  @service_by_id Map.new(@services, &{&1.id, &1})

  @spec all() :: [Service.t()]
  def all, do: @services

  @spec fetch!(String.t()) :: Service.t()
  def fetch!(id) when is_binary(id) do
    Map.get(@service_by_id, id) ||
      raise ArgumentError, "unknown My Paw Trainer service: #{inspect(id)}"
  end

  def fetch!(_), do: raise(ArgumentError, "service ID must be a string")

  @spec validate_id(term()) ::
          {:ok, String.t()} | {:error, :invalid_service_id | :unknown_service}
  def validate_id(id) when is_binary(id) do
    cond do
      not Regex.match?(@service_id_format, id) -> {:error, :invalid_service_id}
      Map.has_key?(@service_by_id, id) -> {:ok, id}
      true -> {:error, :unknown_service}
    end
  end

  def validate_id(_), do: {:error, :invalid_service_id}

  @spec direct_booking_ids() :: [String.t()]
  def direct_booking_ids, do: Enum.filter(@services, & &1.direct_bookable) |> Enum.map(& &1.id)

  @spec direct_bookable?(term()) :: boolean()
  def direct_bookable?(id) when is_binary(id),
    do: match?(%Service{direct_bookable: true}, Map.get(@service_by_id, id))

  def direct_bookable?(_), do: false

  @spec route_metadata(Service.t()) :: map()
  def route_metadata(%Service{} = service),
    do: %{
      id: service.id,
      route: service.route,
      direct_bookable: service.direct_bookable,
      cta: service.cta
    }

  @spec snapshot(map()) :: map()
  def snapshot(%{
        service_id: service_id,
        price_cents: price_cents,
        currency: "usd",
        version: version
      })
      when is_integer(price_cents) and price_cents > 0 and is_integer(version) and version > 0 do
    service = fetch!(service_id)

    if service.direct_bookable do
      %{
        "service_id" => service.id,
        "service_name" => service.name,
        "amount_cents" => price_cents,
        "currency" => "usd",
        "duration_minutes" => service.duration_minutes,
        "delivery_mode" => service.delivery_mode,
        "event_type_version" => version
      }
    else
      raise ArgumentError, "service is not directly bookable"
    end
  end

  def snapshot(_), do: raise(ArgumentError, "invalid direct service configuration")
end
