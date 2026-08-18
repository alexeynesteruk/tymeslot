defmodule Tymeslot.Repo.Migrations.CreateFollowUpEntitlements do
  use Ecto.Migration

  def change do
    create table(:follow_up_entitlements, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_user_id, references(:users, on_delete: :delete_all), null: false)
      add(:attendee_hash, :binary, null: false)
      add(:status, :string, null: false, default: "available")
      add(:meeting_timezone, :string, null: false)
      add(:not_before, :utc_datetime, null: false)
      add(:expires_at, :utc_datetime, null: false)

      add(:source_meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:redeemed_meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all))
      add(:consumed_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:follow_up_entitlements, [:source_meeting_id]))
    create(index(:follow_up_entitlements, [:owner_user_id, :status]))
    create(index(:follow_up_entitlements, [:expires_at]))

    create table(:follow_up_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token_hash, :binary, null: false)
      add(:attendee_hash, :binary, null: false)
      add(:delivered_at, :utc_datetime, null: false)
      add(:invalidated_at, :utc_datetime)
      add(:consumed_at, :utc_datetime)
      add(:invalid_attempt_count, :integer, null: false, default: 0)

      add(
        :entitlement_id,
        references(:follow_up_entitlements, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:follow_up_links, [:token_hash]))
    create(index(:follow_up_links, [:entitlement_id]))
  end
end
