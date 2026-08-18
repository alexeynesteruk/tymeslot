defmodule Tymeslot.Bookings.ManagementTokens do
  @moduledoc "Issues and validates hashed, attendee-bound rescheduling tokens."

  import Ecto.Query

  alias Tymeslot.Bookings.ManagementTokenSchema
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @purpose "reschedule"
  @invalid :invalid_management_link

  @spec issue(MeetingSchema.t()) ::
          {:ok, String.t(), ManagementTokenSchema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def issue(%MeetingSchema{} = meeting) do
    with {:ok, expires_at} <- expiry_for(meeting) do
      raw_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      now = Clock.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        token_hash: token_hash(raw_token),
        attendee_hash: attendee_hash(meeting.attendee_email),
        purpose: @purpose,
        expires_at: expires_at,
        meeting_id: meeting.id
      }

      Repo.transaction(fn ->
        from(m in MeetingSchema, where: m.id == ^meeting.id, lock: "FOR UPDATE")
        |> Repo.one!()

        from(t in ManagementTokenSchema,
          where: t.meeting_id == ^meeting.id and t.purpose == @purpose and is_nil(t.consumed_at)
        )
        |> Repo.update_all(set: [consumed_at: now, updated_at: now])

        case %ManagementTokenSchema{}
             |> ManagementTokenSchema.changeset(attrs)
             |> Repo.insert() do
          {:ok, token} -> {raw_token, token}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {raw, token}} -> {:ok, raw, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec resolve(String.t(), keyword()) ::
          {:ok, MeetingSchema.t(), ManagementTokenSchema.t()} | {:error, :invalid_management_link}
  def resolve(raw_token, opts \\ []) when is_binary(raw_token) do
    now = Keyword.get(opts, :now, Clock.utc_now()) |> DateTime.truncate(:second)

    token =
      from(t in ManagementTokenSchema,
        where: t.token_hash == ^token_hash(raw_token) and t.purpose == @purpose,
        preload: [:meeting]
      )
      |> Repo.one()

    validate(token, now)
  end

  @spec consume_and_rotate(String.t()) ::
          {:ok, String.t(), ManagementTokenSchema.t()}
          | {:error, :invalid_management_link | term()}
  def consume_and_rotate(raw_token, meeting_override \\ nil) do
    Repo.transaction(fn ->
      now = Clock.utc_now() |> DateTime.truncate(:second)

      token =
        from(t in ManagementTokenSchema,
          where: t.token_hash == ^token_hash(raw_token) and t.purpose == @purpose,
          lock: "FOR UPDATE",
          preload: [:meeting]
        )
        |> Repo.one()

      with {:ok, meeting, token} <- validate(token, now),
           {:ok, _consumed} <-
             token
             |> ManagementTokenSchema.changeset(%{consumed_at: now})
             |> Repo.update(),
           {:ok, replacement_raw, replacement} <- issue(meeting_override || meeting) do
        {replacement_raw, replacement}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {raw, token}} -> {:ok, raw, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec management_url(String.t(), String.t()) :: String.t()
  def management_url(username, raw_token),
    do: TymeslotWeb.Endpoint.url() <> "/#{username}/manage/#{raw_token}"

  @doc "Adds a transient management URL to email details without persisting the raw token."
  @spec prepare_email_details(MeetingSchema.t(), map()) :: map()
  def prepare_email_details(meeting, details) do
    if ServiceCatalog.direct_bookable?(get_in(meeting.service_snapshot, ["service_id"])) do
      details
      |> Map.put(:service_id, get_in(meeting.service_snapshot, ["service_id"]))
      |> Map.put(:cancel_url, nil)
      |> Map.put(:reschedule_url, issue_email_url(meeting))
    else
      details
    end
  end

  defp issue_email_url(meeting) do
    with {:ok, %{username: username}} when is_binary(username) <-
           ProfileQueries.get_by_user_id(meeting.organizer_user_id),
         {:ok, raw_token, _stored} <- issue(meeting) do
      management_url(username, raw_token)
    else
      _unavailable -> nil
    end
  end

  defp validate(nil, _now), do: {:error, @invalid}

  defp validate(%{meeting: meeting} = token, now) do
    valid =
      with {:ok, configured_deadline} <- expiry_for(meeting) do
        is_nil(token.consumed_at) and
          DateTime.compare(token.expires_at, now) == :gt and
          DateTime.compare(configured_deadline, now) == :gt and
          ServiceCatalog.direct_bookable?(get_in(meeting.service_snapshot, ["service_id"])) and
          Plug.Crypto.secure_compare(token.attendee_hash, attendee_hash(meeting.attendee_email))
      else
        {:error, :deadline_not_configured} -> false
      end

    if valid, do: {:ok, meeting, token}, else: invalid(token)
  end

  defp invalid(token) do
    token
    |> Ecto.Changeset.change(invalid_attempt_count: token.invalid_attempt_count + 1)
    |> Repo.update()

    {:error, @invalid}
  end

  defp expiry_for(%{organizer_user_id: owner_id, start_time: %DateTime{} = starts_at}) do
    deadlines = Application.get_env(:tymeslot, :mypawtrainer_reschedule_deadlines, %{})

    case Map.get(deadlines, owner_id) do
      hours when is_integer(hours) and hours >= 0 ->
        {:ok, DateTime.add(starts_at, -hours, :hour) |> DateTime.truncate(:second)}

      _other ->
        {:error, :deadline_not_configured}
    end
  end

  defp expiry_for(_meeting), do: {:error, :deadline_not_configured}
  defp token_hash(raw), do: :crypto.hash(:sha256, raw)

  defp attendee_hash(email),
    do: :crypto.hash(:sha256, email |> String.trim() |> String.downcase())
end
