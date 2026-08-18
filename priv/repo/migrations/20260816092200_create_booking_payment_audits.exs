defmodule Tymeslot.Repo.Migrations.CreateBookingPaymentAudits do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # Brand-new empty audit table.

  def change do
    create table(:booking_payment_audits, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:booking_payment_id, :binary_id, null: false)
      add(:meeting_id, :binary_id)
      add(:actor_type, :string, null: false)
      add(:actor_user_id, :integer)
      add(:action, :string, null: false)
      add(:attempt, :integer, null: false, default: 0)
      add(:amount_cents, :integer)
      add(:result, :string, null: false)
      add(:stripe_object_id, :string)
      add(:detail_code, :string)
      add(:occurred_at, :utc_datetime, null: false)
    end

    create(index(:booking_payment_audits, [:booking_payment_id, :occurred_at]))
    create(index(:booking_payment_audits, [:meeting_id]))

    create(
      constraint(:booking_payment_audits, :booking_payment_audits_attempt_non_negative,
        check: "attempt >= 0"
      )
    )
  end
end
