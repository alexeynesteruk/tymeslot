defmodule Tymeslot.MyPawTrainer.CrmProjection do
  @moduledoc "Builds the allowlisted, booking-only EspoCRM projection."

  import Ecto.Query

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MyPawTrainer.ProjectionOutbox
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo

  @states ~w(confirmed rescheduled completed cancelled expired)
  @event_types Map.new(@states, &{&1, "booking.#{&1}.v1"})
  @schema_version 1

  @spec append(MeetingSchema.t(), String.t(), keyword()) ::
          {:ok, ProjectionOutboxSchema.t()} | {:error, term()}
  def append(meeting, state, opts \\ [])

  def append(%MeetingSchema{} = meeting, state, opts) when state in @states do
    if Repo.in_transaction?() do
      with :ok <- validate_meeting(meeting),
           {:ok, payload} <- build_payload(meeting, state, opts) do
        occurred_at = Keyword.get(opts, :now, DateTime.utc_now(:second))

        aggregate_version =
          Keyword.get_lazy(opts, :aggregate_version, fn -> next_version(meeting.id) end)

        payload = Map.put(payload, "aggregate_version", aggregate_version)

        ProjectionOutbox.append(%{
          event_id: Ecto.UUID.generate(),
          event_type: Map.fetch!(@event_types, state),
          schema_version: @schema_version,
          aggregate_type: "booking",
          aggregate_id: meeting.id,
          aggregate_version: aggregate_version,
          occurred_at: occurred_at,
          payload: payload
        })
      end
    else
      {:error, :transaction_required}
    end
  end

  def append(_meeting, _state, _opts), do: {:error, :invalid_payload}

  def append_client(_attrs), do: {:error, :event_family_disabled}
  def append_dog(_attrs), do: {:error, :event_family_disabled}
  def append_payment(_attrs), do: {:error, :event_family_disabled}
  def append_follow_up(_attrs), do: {:error, :event_family_disabled}

  @spec append_transition(MeetingSchema.t(), String.t()) :: :ok | {:error, term()}
  def append_transition(%MeetingSchema{} = meeting, state) when state in @states do
    if ServiceCatalog.direct_bookable?(get_in(meeting.service_snapshot, ["service_id"])) do
      case append(meeting, state) do
        {:ok, _event} -> :ok
        {:error, :invalid_payload} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp build_payload(meeting, state, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    snapshot = meeting.service_snapshot
    base_url = Keyword.get(opts, :base_url, default_base_url())

    payload = %{
      "booking_id" => meeting.id,
      "service_id" => snapshot["service_id"],
      "service_name" => snapshot["service_name"],
      "appointment_start" => DateTime.to_iso8601(meeting.start_time),
      "appointment_end" => DateTime.to_iso8601(meeting.end_time),
      "time_zone" => meeting.attendee_timezone,
      "delivery_mode" => snapshot["delivery_mode"],
      "booking_state" => state,
      "aggregate_version" => 0,
      "last_sync_time" => DateTime.to_iso8601(now),
      "operator_deep_link" => operator_deep_link(base_url, meeting.id)
    }

    case Keyword.get(opts, :extra_payload, %{}) do
      extras when extras == %{} -> {:ok, payload}
      _extras -> {:error, :invalid_payload}
    end
  end

  defp validate_meeting(%{
         id: id,
         start_time: %DateTime{},
         end_time: %DateTime{},
         attendee_timezone: zone,
         service_snapshot: snapshot
       })
       when is_binary(id) and is_binary(zone) and is_map(snapshot) do
    if ServiceCatalog.direct_bookable?(snapshot["service_id"]) and
         present?(snapshot["service_name"]) and
         snapshot["delivery_mode"] in ["virtual", "in_home"] do
      :ok
    else
      {:error, :invalid_payload}
    end
  end

  defp validate_meeting(_meeting), do: {:error, :invalid_payload}

  defp next_version(booking_id) do
    (Repo.one(
       from event in ProjectionOutboxSchema,
         where: event.aggregate_type == "booking" and event.aggregate_id == ^booking_id,
         select: max(event.aggregate_version)
     ) || 0) + 1
  end

  defp default_base_url do
    Application.get_env(
      :tymeslot,
      :crm_projection_operator_base_url,
      "https://book.mypawtrainer.com"
    )
  end

  defp operator_deep_link(base_url, booking_id) do
    uri = URI.parse(base_url)

    if uri.scheme in ["http", "https"] and present?(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) do
      URI.to_string(%{uri | path: "/dashboard/meetings", query: "booking_id=#{booking_id}"})
    else
      nil
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
