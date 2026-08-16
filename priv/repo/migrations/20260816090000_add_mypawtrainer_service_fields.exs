defmodule Tymeslot.Repo.Migrations.AddMypawtrainerServiceFields do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add(:service_id, :string)
      add(:service_price_cents, :integer)
      add(:service_currency, :string)
      add(:event_type_version, :integer)
    end

    alter table(:meetings) do
      add(:service_snapshot, :map, null: false, default: %{})
    end

    create(
      unique_index(:meeting_types, [:user_id, :service_id],
        where: "is_active = true AND service_id IS NOT NULL",
        name: :meeting_types_one_active_service_per_owner
      )
    )

    create(
      constraint(:meeting_types, :mypawtrainer_service_fields_complete,
        check:
          "(service_id IS NULL AND service_price_cents IS NULL AND service_currency IS NULL AND event_type_version IS NULL) OR (service_id IS NOT NULL AND service_price_cents IS NOT NULL AND service_currency IS NOT NULL AND event_type_version IS NOT NULL)"
      )
    )

    create(
      constraint(:meeting_types, :mypawtrainer_service_price_positive,
        check:
          "service_id IS NULL OR (service_price_cents IS NOT NULL AND service_price_cents > 0)"
      )
    )

    create(
      constraint(:meeting_types, :mypawtrainer_service_currency_usd,
        check: "service_id IS NULL OR service_currency = 'usd'"
      )
    )

    create(
      constraint(:meeting_types, :mypawtrainer_service_version_positive,
        check: "service_id IS NULL OR (event_type_version IS NOT NULL AND event_type_version > 0)"
      )
    )

    create(
      constraint(:meetings, :mypawtrainer_service_snapshot_object,
        check: "jsonb_typeof(service_snapshot) = 'object'"
      )
    )
  end
end
