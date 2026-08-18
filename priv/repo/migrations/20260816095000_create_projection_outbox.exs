defmodule Tymeslot.Repo.Migrations.CreateProjectionOutbox do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # Brand-new empty outbox table.

  def change do
    create table(:projection_outbox, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:event_id, :binary_id, null: false)
      add(:event_type, :string, null: false)
      add(:schema_version, :integer, null: false)
      add(:aggregate_type, :string, null: false)
      add(:aggregate_id, :string, null: false)
      add(:aggregate_version, :integer, null: false)
      add(:occurred_at, :utc_datetime, null: false)
      add(:payload, :map, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime, null: false)
      add(:error_code, :string)
      add(:delivered_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:projection_outbox, [:event_id]))

    create(
      unique_index(
        :projection_outbox,
        [:aggregate_type, :aggregate_id, :aggregate_version, :event_type],
        name: :projection_outbox_aggregate_event_index
      )
    )

    create(index(:projection_outbox, [:state, :next_attempt_at]))

    create(
      constraint(:projection_outbox, :projection_outbox_state_check,
        check: "state IN ('pending', 'delivering', 'delivered', 'dead_letter')"
      )
    )

    create(
      constraint(:projection_outbox, :projection_outbox_attempt_count_check,
        check: "attempt_count >= 0"
      )
    )
  end
end
