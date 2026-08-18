defmodule Tymeslot.Repo.Migrations.CreateManagementTokens do
  use Ecto.Migration

  def change do
    create table(:management_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token_hash, :binary, null: false)
      add(:attendee_hash, :binary, null: false)
      add(:purpose, :string, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:consumed_at, :utc_datetime)
      add(:invalid_attempt_count, :integer, null: false, default: 0)

      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:management_tokens, [:token_hash]))
    create(index(:management_tokens, [:meeting_id, :purpose]))
    create(index(:management_tokens, [:expires_at]))
  end
end
