defmodule Tymeslot.Bookings.ManagementTokenSchema do
  @moduledoc "Persistent hashed attendee management token."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "management_tokens" do
    field :token_hash, :binary
    field :attendee_hash, :binary
    field :purpose, :string, default: "reschedule"
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    field :invalid_attempt_count, :integer, default: 0

    belongs_to :meeting, Tymeslot.Meetings.MeetingSchema

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :attendee_hash,
      :purpose,
      :expires_at,
      :consumed_at,
      :invalid_attempt_count,
      :meeting_id
    ])
    |> validate_required([:token_hash, :attendee_hash, :purpose, :expires_at, :meeting_id])
    |> validate_inclusion(:purpose, ["reschedule"])
    |> unique_constraint(:token_hash)
  end
end
