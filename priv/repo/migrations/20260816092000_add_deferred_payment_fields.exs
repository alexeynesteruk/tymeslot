defmodule Tymeslot.Repo.Migrations.AddDeferredPaymentFields do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add(:payment_timing, :string)
    end

    alter table(:booking_payments) do
      add(:payment_timing, :string, null: false, default: "upfront")
      add(:service_snapshot, :map, null: false, default: %{})
      add(:stripe_customer_id, :string)
      add(:stripe_setup_intent_id, :string)
      add(:stripe_payment_method_id, :string)
      add(:stripe_recovery_session_id, :string)
      add(:charge_attempt, :integer, null: false, default: 0)
      add(:charge_requested_at, :utc_datetime)
      add(:last_error_code, :string)
    end

    create(
      constraint(:meeting_types, :meeting_types_payment_timing_valid,
        check: "payment_timing IS NULL OR payment_timing IN ('upfront', 'deferred')"
      )
    )

    create(
      constraint(:booking_payments, :booking_payments_payment_timing_valid,
        check: "payment_timing IN ('upfront', 'deferred')"
      )
    )

    create(
      constraint(:booking_payments, :booking_payments_service_snapshot_object,
        check: "jsonb_typeof(service_snapshot) = 'object'"
      )
    )

    create(
      constraint(:booking_payments, :booking_payments_deferred_snapshot_present,
        check:
          "payment_timing <> 'deferred' OR (service_snapshot <> '{}'::jsonb AND stripe_account_id IS NOT NULL AND amount_cents > 0 AND currency IS NOT NULL)"
      )
    )

    create(
      constraint(:booking_payments, :booking_payments_charge_attempt_non_negative,
        check: "charge_attempt >= 0"
      )
    )

    create(
      unique_index(:booking_payments, [:stripe_setup_intent_id],
        where: "stripe_setup_intent_id IS NOT NULL",
        name: :booking_payments_stripe_setup_intent_id_index
      )
    )

    create(
      unique_index(:booking_payments, [:stripe_recovery_session_id],
        where: "stripe_recovery_session_id IS NOT NULL",
        name: :booking_payments_stripe_recovery_session_id_index
      )
    )
  end
end
