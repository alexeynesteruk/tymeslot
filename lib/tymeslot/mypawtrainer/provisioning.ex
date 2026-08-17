defmodule Tymeslot.MyPawTrainer.Provisioning do
  @moduledoc "Idempotent provisioning of the three direct My Paw Trainer event types."

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo

  @spec provision_direct_services(integer()) ::
          {:ok, [MeetingTypeSchema.t()]}
          | {:error, :invalid_owner_id | Ecto.Changeset.t() | term()}
  def provision_direct_services(owner_id) when is_integer(owner_id) and owner_id > 0 do
    Repo.transaction(fn ->
      case MeetingTypeQueries.lock_owner(owner_id) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      existing = MeetingTypeQueries.list_all_meeting_types(owner_id)

      Enum.map(ServiceCatalog.all(), fn service ->
        if service.direct_bookable do
          provision_service(owner_id, service, existing)
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  def provision_direct_services(_owner_id), do: {:error, :invalid_owner_id}

  defp provision_service(owner_id, service, existing) do
    case Enum.find(existing, &(&1.service_id == service.id and &1.is_active)) do
      %MeetingTypeSchema{} ->
        Repo.rollback(:active_existing_service)

      nil ->
        case Enum.find(existing, &(&1.service_id == service.id)) do
          %MeetingTypeSchema{} = meeting_type ->
            if matches_initial_configuration?(meeting_type, service) do
              meeting_type
            else
              Repo.rollback(:invalid_existing_service_configuration)
            end

          nil ->
            attrs = %{
              user_id: owner_id,
              name: service.name,
              description: service.name,
              duration_minutes: service.duration_minutes,
              icon: "hero-clock",
              is_active: false,
              is_private: false,
              slug: service.route,
              allow_video: false,
              service_id: service.id,
              service_price_cents: service.initial_price_cents,
              service_currency: "usd",
              event_type_version: 1
            }

            case MeetingTypeQueries.create_meeting_type(attrs) do
              {:ok, created} -> created
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
    end
  end

  defp matches_initial_configuration?(meeting_type, service) do
    meeting_type.name == service.name and
      meeting_type.duration_minutes == service.duration_minutes and
      meeting_type.service_price_cents == service.initial_price_cents and
      meeting_type.service_currency == "usd" and
      meeting_type.event_type_version == 1
  end
end
