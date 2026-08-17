defmodule Tymeslot.MyPawTrainer.ZipAllowlistQueries do
  @moduledoc "Owner-scoped reads and writes for the in-home ZIP allowlist."

  import Ecto.Query, warn: false

  alias Tymeslot.MyPawTrainer.ZipAllowlistAuditSchema
  alias Tymeslot.MyPawTrainer.ZipAllowlistSchema
  alias Tymeslot.Repo

  @spec get_by_owner_and_zip(integer(), String.t()) :: ZipAllowlistSchema.t() | nil
  def get_by_owner_and_zip(owner_id, zip_code) do
    Repo.get_by(ZipAllowlistSchema, owner_user_id: owner_id, zip_code: zip_code)
  end

  @spec active?(integer(), String.t()) :: boolean()
  def active?(owner_id, zip_code) do
    query =
      from(row in ZipAllowlistSchema,
        where:
          row.owner_user_id == ^owner_id and row.zip_code == ^zip_code and row.active == true,
        select: row.id
      )

    not is_nil(Repo.one(query))
  end

  @spec list_for_owner(integer()) :: [ZipAllowlistSchema.t()]
  def list_for_owner(owner_id) do
    from(row in ZipAllowlistSchema,
      where: row.owner_user_id == ^owner_id,
      order_by: [desc: row.active, asc: row.zip_code]
    )
    |> Repo.all()
  end

  @spec insert_zip(map()) :: {:ok, ZipAllowlistSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_zip(attrs) do
    %ZipAllowlistSchema{}
    |> ZipAllowlistSchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_zip(ZipAllowlistSchema.t(), map()) ::
          {:ok, ZipAllowlistSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_zip(%ZipAllowlistSchema{} = row, attrs) do
    row
    |> ZipAllowlistSchema.changeset(attrs)
    |> Repo.update()
  end

  @spec insert_audit(map()) :: {:ok, ZipAllowlistAuditSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_audit(attrs) do
    %ZipAllowlistAuditSchema{}
    |> ZipAllowlistAuditSchema.changeset(attrs)
    |> Repo.insert()
  end
end
