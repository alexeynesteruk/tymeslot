defmodule Tymeslot.Repo.Migrations.CreateServiceAreaZips do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # Brand-new empty tables. Foreign keys and indexes cannot rewrite existing
  # rows.

  def change do
    create table(:service_area_zips) do
      add(:owner_user_id, references(:users, on_delete: :delete_all), null: false)
      add(:zip_code, :string, null: false, size: 5)
      add(:active, :boolean, null: false, default: true)
      add(:created_by_user_id, references(:users, on_delete: :restrict), null: false)
      add(:updated_by_user_id, references(:users, on_delete: :restrict), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:service_area_zips, [:owner_user_id, :zip_code]))
    create(index(:service_area_zips, [:owner_user_id, :active]))

    create table(:service_area_zip_audits) do
      add(:owner_user_id, references(:users, on_delete: :delete_all), null: false)
      add(:zip_code, :string, null: false, size: 5)
      add(:action, :string, null: false)
      add(:previous_active, :boolean)
      add(:new_active, :boolean, null: false)
      add(:actor_user_id, references(:users, on_delete: :restrict), null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:service_area_zip_audits, [:owner_user_id, :inserted_at]))
  end
end
