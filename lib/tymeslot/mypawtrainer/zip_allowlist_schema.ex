defmodule Tymeslot.MyPawTrainer.ZipAllowlistSchema do
  @moduledoc "Owner-scoped active ZIP for in-home eligibility."

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          owner_user_id: integer() | nil,
          zip_code: String.t() | nil,
          active: boolean(),
          created_by_user_id: integer() | nil,
          updated_by_user_id: integer() | nil,
          owner: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          created_by: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          updated_by: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "service_area_zips" do
    field(:zip_code, :string)
    field(:active, :boolean, default: true)

    belongs_to(:owner, UserSchema, foreign_key: :owner_user_id)
    belongs_to(:created_by, UserSchema, foreign_key: :created_by_user_id)
    belongs_to(:updated_by, UserSchema, foreign_key: :updated_by_user_id)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :owner_user_id,
      :zip_code,
      :active,
      :created_by_user_id,
      :updated_by_user_id
    ])
    |> validate_required([
      :owner_user_id,
      :zip_code,
      :active,
      :created_by_user_id,
      :updated_by_user_id
    ])
    |> validate_format(:zip_code, ~r/\A[0-9]{5}\z/)
    |> unique_constraint([:owner_user_id, :zip_code])
    |> foreign_key_constraint(:owner_user_id)
  end
end
