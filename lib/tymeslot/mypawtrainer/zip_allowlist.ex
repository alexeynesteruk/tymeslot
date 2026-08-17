defmodule Tymeslot.MyPawTrainer.ZipAllowlist do
  @moduledoc "Anna-managed ZIP eligibility and audit for in-home booking."

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MyPawTrainer.ZipAllowlistQueries
  alias Tymeslot.Repo

  @zip_format ~r/\A[0-9]{5}\z/
  @in_home_id "in-home-consultation"

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_zip}
  def normalize(zip) when is_binary(zip) do
    digits = zip |> String.trim() |> String.replace(~r/[^0-9]/, "")

    if String.match?(digits, @zip_format) and String.trim(zip) == digits do
      {:ok, digits}
    else
      {:error, :invalid_zip}
    end
  end

  def normalize(_), do: {:error, :invalid_zip}

  @spec eligible?(integer(), term()) :: boolean()
  def eligible?(owner_id, zip) when is_integer(owner_id) do
    case normalize(zip) do
      {:ok, zip_code} -> ZipAllowlistQueries.active?(owner_id, zip_code)
      {:error, :invalid_zip} -> false
    end
  end

  def eligible?(_owner_id, _zip), do: false

  @spec set_active(integer(), term(), keyword()) ::
          {:ok, Tymeslot.MyPawTrainer.ZipAllowlistSchema.t()}
          | {:error, :unauthorized | :invalid_zip | :owner_not_found | Ecto.Changeset.t()}
  def set_active(owner_id, zip, opts) when is_integer(owner_id) and is_list(opts) do
    actor_id = Keyword.get(opts, :actor_id)
    active = Keyword.get(opts, :active)

    cond do
      not is_integer(actor_id) or actor_id != owner_id ->
        {:error, :unauthorized}

      not is_boolean(active) ->
        {:error, :invalid_zip}

      true ->
        with {:ok, zip_code} <- normalize(zip) do
          write_change(owner_id, zip_code, active, actor_id)
        end
    end
  end

  def set_active(_owner_id, _zip, _opts), do: {:error, :unauthorized}

  @spec list_for_owner(integer()) :: [Tymeslot.MyPawTrainer.ZipAllowlistSchema.t()]
  def list_for_owner(owner_id) when is_integer(owner_id),
    do: ZipAllowlistQueries.list_for_owner(owner_id)

  def list_for_owner(_owner_id), do: []

  @spec authorize_schedule(map(), term()) :: :ok | {:error, :service_area_unavailable}
  def authorize_schedule(%{service_id: @in_home_id, user_id: owner_id}, zip)
      when is_integer(owner_id) do
    if eligible?(owner_id, zip), do: :ok, else: {:error, :service_area_unavailable}
  end

  def authorize_schedule(%{service_id: service_id}, _zip)
      when is_binary(service_id) do
    if service_id == @in_home_id do
      {:error, :service_area_unavailable}
    else
      :ok
    end
  end

  def authorize_schedule(_meeting_type, _zip), do: :ok

  @spec requires_zip?(map() | nil) :: boolean()
  def requires_zip?(%{service_id: @in_home_id}), do: true
  def requires_zip?(_), do: false

  defp write_change(owner_id, zip_code, active, actor_id) do
    Repo.transaction(fn ->
      case MeetingTypeQueries.lock_owner(owner_id) do
        :ok -> persist_change(owner_id, zip_code, active, actor_id)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp persist_change(owner_id, zip_code, active, actor_id) do
    case ZipAllowlistQueries.get_by_owner_and_zip(owner_id, zip_code) do
      nil ->
        insert_zip(owner_id, zip_code, active, actor_id)

      %{active: ^active} = row ->
        row

      row ->
        update_zip(row, active, actor_id)
    end
  end

  defp insert_zip(owner_id, zip_code, active, actor_id) do
    attrs = %{
      owner_user_id: owner_id,
      zip_code: zip_code,
      active: active,
      created_by_user_id: actor_id,
      updated_by_user_id: actor_id
    }

    with {:ok, row} <- ZipAllowlistQueries.insert_zip(attrs),
         {:ok, _audit} <-
           insert_audit(owner_id, zip_code, "add", nil, active, actor_id) do
      row
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_zip(row, active, actor_id) do
    action = if active, do: "reactivate", else: "deactivate"

    with {:ok, updated} <-
           ZipAllowlistQueries.update_zip(row, %{active: active, updated_by_user_id: actor_id}),
         {:ok, _audit} <-
           insert_audit(
             row.owner_user_id,
             row.zip_code,
             action,
             row.active,
             active,
             actor_id
           ) do
      updated
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_audit(owner_id, zip_code, action, previous_active, new_active, actor_id) do
    ZipAllowlistQueries.insert_audit(%{
      owner_user_id: owner_id,
      zip_code: zip_code,
      action: action,
      previous_active: previous_active,
      new_active: new_active,
      actor_user_id: actor_id
    })
  end
end
