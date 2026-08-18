defmodule Tymeslot.MyPawTrainer.FollowUpLinkSchema do
  @moduledoc "Hashed, client-bound link for a follow-up entitlement."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "follow_up_links" do
    field :token_hash, :binary
    field :attendee_hash, :binary
    field :delivered_at, :utc_datetime
    field :invalidated_at, :utc_datetime
    field :consumed_at, :utc_datetime
    field :invalid_attempt_count, :integer, default: 0

    belongs_to :entitlement, Tymeslot.MyPawTrainer.FollowUpEntitlementSchema
    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :token_hash,
      :attendee_hash,
      :delivered_at,
      :invalidated_at,
      :consumed_at,
      :invalid_attempt_count,
      :entitlement_id
    ])
    |> validate_required([:token_hash, :attendee_hash, :delivered_at, :entitlement_id])
    |> unique_constraint(:token_hash)
  end
end
