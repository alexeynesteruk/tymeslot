defmodule Tymeslot.MyPawTrainer.ZipAllowlistAuditSchema do
  @moduledoc "Immutable audit row for an owner ZIP allowlist change."

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          owner_user_id: integer() | nil,
          zip_code: String.t() | nil,
          action: String.t() | nil,
          previous_active: boolean() | nil,
          new_active: boolean() | nil,
          actor_user_id: integer() | nil,
          owner: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          actor: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil
        }

  schema "service_area_zip_audits" do
    field(:zip_code, :string)
    field(:action, :string)
    field(:previous_active, :boolean)
    field(:new_active, :boolean)

    belongs_to(:owner, UserSchema, foreign_key: :owner_user_id)
    belongs_to(:actor, UserSchema, foreign_key: :actor_user_id)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :owner_user_id,
      :zip_code,
      :action,
      :previous_active,
      :new_active,
      :actor_user_id
    ])
    |> validate_required([
      :owner_user_id,
      :zip_code,
      :action,
      :new_active,
      :actor_user_id
    ])
    |> validate_inclusion(:action, ~w(add deactivate reactivate))
    |> validate_format(:zip_code, ~r/\A[0-9]{5}\z/)
    |> foreign_key_constraint(:owner_user_id)
  end
end
