defmodule Tymeslot.MyPawTrainer.ProjectionOutboxSchema do
  @moduledoc "Persistent transactional projection event."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @states ~w(pending delivering delivered dead_letter)

  @type t :: %__MODULE__{}

  schema "projection_outbox" do
    field :event_id, Ecto.UUID
    field :event_type, :string
    field :schema_version, :integer
    field :aggregate_type, :string
    field :aggregate_id, :string
    field :aggregate_version, :integer
    field :occurred_at, :utc_datetime
    field :payload, :map
    field :state, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :error_code, :string
    field :delivered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :event_type,
      :schema_version,
      :aggregate_type,
      :aggregate_id,
      :aggregate_version,
      :occurred_at,
      :payload,
      :state,
      :attempt_count,
      :next_attempt_at,
      :error_code,
      :delivered_at
    ])
    |> validate_required([
      :event_id,
      :event_type,
      :schema_version,
      :aggregate_type,
      :aggregate_id,
      :aggregate_version,
      :occurred_at,
      :payload,
      :state,
      :attempt_count,
      :next_attempt_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_number(:schema_version, greater_than: 0)
    |> validate_number(:aggregate_version, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:event_id)
    |> unique_constraint(
      [:aggregate_type, :aggregate_id, :aggregate_version, :event_type],
      name: :projection_outbox_aggregate_event_index
    )
  end
end
