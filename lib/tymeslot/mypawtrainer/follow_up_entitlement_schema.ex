defmodule Tymeslot.MyPawTrainer.FollowUpEntitlementSchema do
  @moduledoc "One included follow-up earned by a completed consultation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "follow_up_entitlements" do
    field :owner_user_id, :integer
    field :attendee_hash, :binary
    field :status, :string, default: "available"
    field :meeting_timezone, :string
    field :not_before, :utc_datetime
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :source_meeting, Tymeslot.Meetings.MeetingSchema
    belongs_to :redeemed_meeting, Tymeslot.Meetings.MeetingSchema
    has_many :links, Tymeslot.MyPawTrainer.FollowUpLinkSchema, foreign_key: :entitlement_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :owner_user_id,
      :attendee_hash,
      :status,
      :meeting_timezone,
      :not_before,
      :expires_at,
      :source_meeting_id,
      :redeemed_meeting_id,
      :consumed_at
    ])
    |> validate_required([
      :owner_user_id,
      :attendee_hash,
      :status,
      :meeting_timezone,
      :not_before,
      :expires_at,
      :source_meeting_id
    ])
    |> validate_inclusion(:status, ["available", "consumed"])
    |> unique_constraint(:source_meeting_id)
  end
end
