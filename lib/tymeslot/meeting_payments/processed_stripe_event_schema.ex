defmodule Tymeslot.MeetingPayments.ProcessedStripeEventSchema do
  @moduledoc """
  Durable Stripe event claim used for replay-safe webhook processing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(processing completed failed)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stripe_event_id: String.t() | nil,
          event_type: String.t() | nil,
          status: String.t(),
          attempt_count: integer(),
          error: String.t() | nil,
          processed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "processed_stripe_events" do
    field :stripe_event_id, :string
    field :event_type, :string
    field :status, :string, default: "processing"
    field :attempt_count, :integer, default: 1
    field :error, :string
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:stripe_event_id, :event_type, :status, :attempt_count, :error, :processed_at])
    |> validate_required([:stripe_event_id, :event_type, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:attempt_count, greater_than: 0)
    |> unique_constraint(:stripe_event_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:status, :attempt_count, :error, :processed_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:attempt_count, greater_than: 0)
  end
end
