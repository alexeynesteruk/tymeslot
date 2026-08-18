defmodule Tymeslot.MyPawTrainer.EventRoutes do
  @moduledoc "Stable public scheduler paths for directly bookable services."

  import Ecto.Query

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo

  @prefix "/anna/"

  @spec path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def path(service_id) do
    case ServiceCatalog.validate_id(service_id) do
      {:ok, id} ->
        if ServiceCatalog.direct_bookable?(id),
          do: {:ok, @prefix <> ServiceCatalog.fetch!(id).route},
          else: {:error, :approval_first}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resolve(integer(), String.t()) :: {:ok, map()} | {:error, atom()}
  def resolve(owner_id, service_id) when is_integer(owner_id) do
    with {:ok, stable_path} <- path(service_id) do
      route = ServiceCatalog.fetch!(service_id).route

      query =
        from event_type in MeetingTypeSchema,
          where:
            event_type.user_id == ^owner_id and event_type.service_id == ^service_id and
              event_type.slug == ^route and event_type.is_active == true,
          select: event_type.id

      case Repo.one(query) do
        nil -> {:error, :unavailable}
        id -> {:ok, %{path: stable_path, meeting_type_id: id}}
      end
    end
  end

  def resolve(_owner_id, service_id) do
    with {:ok, _path} <- path(service_id), do: {:error, :unavailable}
  end
end
