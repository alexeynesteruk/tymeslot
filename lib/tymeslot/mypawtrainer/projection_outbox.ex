defmodule Tymeslot.MyPawTrainer.ProjectionOutbox do
  @moduledoc "Transactional append and delivery-state queries for projection events."

  import Ecto.Query

  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.Repo

  @price_event "service.price_published.v1"
  @price_payload_keys MapSet.new(
                        ~w(event_id service_id cents currency event_type_version aggregate_version occurred_at schema_version)
                      )
  @error_code_format ~r/\A[a-z0-9]+(?:_[a-z0-9]+)*\z/

  @spec append(map()) :: {:ok, ProjectionOutboxSchema.t()} | {:error, term()}
  def append(attrs) do
    if Repo.in_transaction?() do
      with :ok <- validate_payload(attrs) do
        now = Map.fetch!(attrs, :occurred_at)
        attrs = Map.put_new(attrs, :next_attempt_at, now)

        case %ProjectionOutboxSchema{}
             |> ProjectionOutboxSchema.changeset(attrs)
             |> Repo.insert(
               on_conflict: :nothing,
               conflict_target: [
                 :aggregate_type,
                 :aggregate_id,
                 :aggregate_version,
                 :event_type
               ]
             ) do
          {:ok, _inserted_or_duplicate} -> {:ok, producer_event!(attrs)}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:error, :transaction_required}
    end
  end

  @spec claim_due(pos_integer(), DateTime.t()) :: [ProjectionOutboxSchema.t()]
  def claim_due(limit, now) when is_integer(limit) and limit > 0 do
    {:ok, events} =
      Repo.transaction(fn ->
        due =
          ProjectionOutboxSchema
          |> where([event], event.state == "pending" and event.next_attempt_at <= ^now)
          |> order_by([event], asc: event.next_attempt_at, asc: event.inserted_at)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()

        Enum.map(due, fn event ->
          event
          |> Ecto.Changeset.change(
            state: "delivering",
            attempt_count: event.attempt_count + 1,
            error_code: nil
          )
          |> Repo.update!()
        end)
      end)

    events
  end

  @spec mark_delivered(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, ProjectionOutboxSchema.t()} | {:error, :not_delivering}
  def mark_delivered(id, delivered_at) do
    transition(id, "delivering", %{
      state: "delivered",
      delivered_at: delivered_at,
      error_code: nil
    })
  end

  @spec reschedule_retry(Ecto.UUID.t(), String.t(), DateTime.t()) ::
          {:ok, ProjectionOutboxSchema.t()} | {:error, atom()}
  def reschedule_retry(id, error_code, next_attempt_at) do
    with :ok <- validate_error_code(error_code) do
      transition(id, "delivering", %{
        state: "pending",
        error_code: error_code,
        next_attempt_at: next_attempt_at
      })
    end
  end

  @spec dead_letter(Ecto.UUID.t(), String.t()) ::
          {:ok, ProjectionOutboxSchema.t()} | {:error, atom()}
  def dead_letter(id, error_code) do
    with :ok <- validate_error_code(error_code) do
      transition(id, ["pending", "delivering"], %{state: "dead_letter", error_code: error_code})
    end
  end

  defp transition(id, expected_states, attrs) do
    expected_states = List.wrap(expected_states)

    case Repo.transaction(fn ->
           query =
             from event in ProjectionOutboxSchema,
               where: event.id == ^id and event.state in ^expected_states,
               lock: "FOR UPDATE"

           case Repo.one(query) do
             nil -> Repo.rollback(:not_delivering)
             event -> event |> Ecto.Changeset.change(attrs) |> Repo.update!()
           end
         end) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp producer_event!(attrs) do
    Repo.one!(
      from event in ProjectionOutboxSchema,
        where:
          event.aggregate_type == ^attrs.aggregate_type and
            event.aggregate_id == ^attrs.aggregate_id and
            event.aggregate_version == ^attrs.aggregate_version and
            event.event_type == ^attrs.event_type
    )
  end

  defp validate_payload(%{
         event_id: event_id,
         event_type: @price_event,
         schema_version: 1,
         aggregate_version: aggregate_version,
         payload: payload
       })
       when is_map(payload) do
    cond do
      MapSet.new(Map.keys(payload)) != @price_payload_keys -> {:error, :invalid_payload}
      payload["event_id"] != event_id -> {:error, :invalid_payload}
      payload["schema_version"] != 1 -> {:error, :invalid_payload}
      payload["aggregate_version"] != aggregate_version -> {:error, :invalid_payload}
      true -> :ok
    end
  end

  defp validate_payload(_attrs), do: {:error, :invalid_payload}

  defp validate_error_code(code) when is_binary(code) do
    if byte_size(code) <= 64 and Regex.match?(@error_code_format, code),
      do: :ok,
      else: {:error, :invalid_error_code}
  end

  defp validate_error_code(_code), do: {:error, :invalid_error_code}
end
