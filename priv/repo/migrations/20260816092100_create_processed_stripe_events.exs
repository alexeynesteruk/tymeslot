defmodule Tymeslot.Repo.Migrations.CreateProcessedStripeEvents do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # Brand-new empty ledger table.

  def change do
    create table(:processed_stripe_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:stripe_event_id, :string, null: false)
      add(:event_type, :string, null: false)
      add(:status, :string, null: false, default: "processing")
      add(:attempt_count, :integer, null: false, default: 1)
      add(:error, :string)
      add(:processed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:processed_stripe_events, [:stripe_event_id]))
    create(index(:processed_stripe_events, [:status, :updated_at]))

    create(
      constraint(:processed_stripe_events, :processed_stripe_events_status_valid,
        check: "status IN ('processing', 'completed', 'failed')"
      )
    )

    create(
      constraint(:processed_stripe_events, :processed_stripe_events_attempt_count_positive,
        check: "attempt_count > 0"
      )
    )
  end
end
