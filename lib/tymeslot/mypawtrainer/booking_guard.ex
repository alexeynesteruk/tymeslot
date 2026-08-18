defmodule Tymeslot.MyPawTrainer.BookingGuard do
  @moduledoc """
  Authorizes My Paw Trainer direct-service bookings before persistence.

  Approval-first catalog IDs have no Tymeslot booking route. In-home
  bookings require an active owner ZIP. Duration must match the code-owned
  catalog. The returned snapshot is what the meeting must store.
  """

  alias Tymeslot.MyPawTrainer.Service
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.MyPawTrainer.ZipAllowlist

  @type attrs :: %{optional(atom() | String.t()) => term()}

  @spec service(String.t()) :: Service.t()
  def service(id), do: ServiceCatalog.fetch!(id)

  @spec authorize_service(term(), attrs()) ::
          {:ok, map()}
          | {:error, :service_not_bookable | :invalid_duration | :service_area_unavailable}
  def authorize_service(service_id, attrs) when is_map(attrs) do
    with {:ok, service} <- fetch_direct(service_id),
         :ok <- enforce_duration(service, attrs),
         :ok <- enforce_zip(service, attrs) do
      {:ok, snapshot(service, attrs)}
    end
  end

  def authorize_service(_service_id, _attrs), do: {:error, :service_not_bookable}

  @spec authorize_reschedule(term(), attrs()) :: {:ok, map()} | {:error, atom()}
  def authorize_reschedule(service_id, attrs) when is_map(attrs) do
    with {:ok, service} <- fetch_direct(service_id),
         :ok <- enforce_duration(service, attrs) do
      {:ok, snapshot(service, attrs)}
    end
  end

  def authorize_reschedule(_service_id, _attrs), do: {:error, :service_not_bookable}

  defp fetch_direct(service_id) do
    if ServiceCatalog.direct_bookable?(service_id) do
      {:ok, ServiceCatalog.fetch!(service_id)}
    else
      {:error, :service_not_bookable}
    end
  end

  defp enforce_duration(service, attrs) do
    case attr(attrs, :duration_minutes) do
      nil -> :ok
      duration when duration == service.duration_minutes -> :ok
      _other -> {:error, :invalid_duration}
    end
  end

  defp enforce_zip(%Service{id: "in-home-consultation"}, attrs) do
    owner_id = attr(attrs, :owner_id)
    zip = attr(attrs, :zip)

    if ZipAllowlist.eligible?(owner_id, zip) do
      :ok
    else
      {:error, :service_area_unavailable}
    end
  end

  defp enforce_zip(_service, _attrs), do: :ok

  defp snapshot(service, attrs) do
    meeting_type = attr(attrs, :meeting_type)

    ServiceCatalog.snapshot(%{
      service_id: service.id,
      price_cents: snapshot_price(service, meeting_type),
      currency: "usd",
      version: snapshot_version(meeting_type)
    })
  end

  defp snapshot_price(_service, %{service_price_cents: cents})
       when is_integer(cents) and cents > 0,
       do: cents

  defp snapshot_price(service, _meeting_type), do: service.initial_price_cents

  defp snapshot_version(%{event_type_version: version})
       when is_integer(version) and version > 0,
       do: version

  defp snapshot_version(_meeting_type), do: 1

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
