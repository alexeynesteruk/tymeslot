defmodule Tymeslot.MyPawTrainer.FollowUps do
  @moduledoc "Issues and atomically redeems included consultation follow-ups."

  import Ecto.Query

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MyPawTrainer.CalendarAvailability
  alias Tymeslot.MyPawTrainer.FollowUpEntitlementSchema, as: Entitlement
  alias Tymeslot.MyPawTrainer.FollowUpLinkSchema, as: Link
  alias Tymeslot.MyPawTrainer.FollowUpTokens
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias UUID

  @eligible_services ["online-consultation", "in-home-consultation"]
  @snapshot %{
    "service_id" => "follow-up",
    "service_name" => "Included follow-up",
    "amount_cents" => 0,
    "duration_minutes" => 30,
    "currency" => "usd",
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  @spec create_entitlement(MeetingSchema.t()) ::
          {:ok, Entitlement.t() | nil} | {:error, Ecto.Changeset.t() | atom()}
  def create_entitlement(%MeetingSchema{} = source) do
    if eligible_source?(source) do
      with {:ok, timezone} <- meeting_timezone(source),
           {:ok, not_before, expires_at} <- redemption_window(source, timezone) do
        %Entitlement{}
        |> Entitlement.changeset(%{
          owner_user_id: source.organizer_user_id,
          attendee_hash: FollowUpTokens.attendee_hash(source.attendee_email),
          status: "available",
          meeting_timezone: timezone,
          not_before: not_before,
          expires_at: expires_at,
          source_meeting_id: source.id
        })
        |> Repo.insert()
      end
    else
      {:ok, nil}
    end
  end

  @spec issue_link(Ecto.UUID.t(), pos_integer()) ::
          {:ok, String.t(), Link.t()} | {:error, atom() | Ecto.Changeset.t()}
  def issue_link(source_meeting_id, actor_user_id) when is_integer(actor_user_id) do
    Repo.transaction(fn ->
      entitlement =
        from(e in Entitlement,
          where: e.source_meeting_id == ^source_meeting_id,
          lock: "FOR UPDATE",
          preload: [:source_meeting]
        )
        |> Repo.one()

      with %Entitlement{} = entitlement <- entitlement,
           :ok <- authorize(entitlement, actor_user_id),
           :ok <- require_completed(entitlement.source_meeting),
           :ok <- require_available(entitlement) do
        now = now()
        raw = FollowUpTokens.generate()

        from(link in Link,
          where: link.entitlement_id == ^entitlement.id and is_nil(link.invalidated_at)
        )
        |> Repo.update_all(set: [invalidated_at: now, updated_at: now])

        case %Link{}
             |> Link.changeset(%{
               entitlement_id: entitlement.id,
               token_hash: FollowUpTokens.hash(raw),
               attendee_hash: entitlement.attendee_hash,
               delivered_at: now
             })
             |> Repo.insert() do
          {:ok, link} -> {raw, link}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {raw, link}} -> {:ok, raw, link}
      {:error, reason} -> {:error, reason}
    end
  end

  def issue_link(_source_meeting_id, _actor_user_id), do: {:error, :not_authorized}

  @spec resolve(String.t(), keyword()) ::
          {:ok, Entitlement.t(), Link.t()} | {:error, :invalid | :not_yet_open | :expired | :used}
  def resolve(raw, opts \\ []) when is_binary(raw) do
    current_time = Keyword.get(opts, :now, Clock.utc_now()) |> DateTime.truncate(:second)

    from(link in Link,
      where: link.token_hash == ^FollowUpTokens.hash(raw),
      preload: [entitlement: :source_meeting]
    )
    |> Repo.one()
    |> validate_link(current_time)
  end

  @spec redeem(String.t(), %{required(:start_time) => DateTime.t()}) ::
          {:ok, MeetingSchema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def redeem(raw, %{start_time: %DateTime{} = starts_at}) when is_binary(raw) do
    Repo.transaction(fn ->
      current_time = now()

      initial_link =
        from(link in Link,
          where: link.token_hash == ^FollowUpTokens.hash(raw)
        )
        |> Repo.one()

      with %Link{} = initial_link <- initial_link,
           %Entitlement{} = entitlement <- lock_entitlement(initial_link.entitlement_id),
           %Link{} = link <- lock_link(initial_link.id, entitlement),
           {:ok, entitlement, link} <- validate_link(link, current_time),
           :ok <- validate_requested_time(starts_at, entitlement),
           :ok <- fresh_calendar_check(entitlement.source_meeting, starts_at),
           {:ok, child} <- create_child(entitlement.source_meeting, starts_at),
           {:ok, _job} <- CalendarJobs.schedule_job(child, "create"),
           {:ok, _entitlement} <- consume_entitlement(entitlement, child, current_time),
           {:ok, _link} <- consume_link(link, current_time) do
        child
      else
        nil -> Repo.rollback(:invalid)
        {:error, :calendar_unverifiable} -> Repo.rollback(:slot_unavailable)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def redeem(_raw, _params), do: {:error, :invalid}

  @doc "Deletes expired follow-up token hashes owned by the host."
  @spec purge_expired(pos_integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def purge_expired(owner_user_id, %DateTime{} = current_time)
      when is_integer(owner_user_id) do
    expired_ids =
      from(link in Link,
        join: entitlement in Entitlement,
        on: entitlement.id == link.entitlement_id,
        where:
          entitlement.owner_user_id == ^owner_user_id and
            entitlement.expires_at <= ^current_time,
        select: link.id
      )

    from(link in Link, where: link.id in subquery(expired_ids))
    |> Repo.delete_all()
  end

  defp eligible_source?(%{status: "completed", service_snapshot: %{"service_id" => id}}),
    do: id in @eligible_services

  defp eligible_source?(_source), do: false

  defp meeting_timezone(%{attendee_timezone: timezone}) when is_binary(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), timezone) do
      {:ok, _datetime} -> {:ok, timezone}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end

  defp meeting_timezone(%{organizer_user_id: owner_id}) do
    case ProfileQueries.get_by_user_id(owner_id) do
      {:ok, %{timezone: timezone}} when is_binary(timezone) -> {:ok, timezone}
      _missing -> {:error, :invalid_timezone}
    end
  end

  defp redemption_window(source, timezone) do
    local_date = source.start_time |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

    not_before = local_date |> Date.add(5) |> local_boundary(~T[00:00:00], timezone)
    expires_at = local_date |> Date.add(10) |> local_boundary(~T[23:59:59], timezone)
    {:ok, not_before, expires_at}
  rescue
    ArgumentError -> {:error, :invalid_timezone}
  end

  defp local_boundary(date, time, timezone) do
    date
    |> DateTime.new!(time, timezone)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp authorize(%{owner_user_id: actor_user_id}, actor_user_id), do: :ok
  defp authorize(_entitlement, _actor_user_id), do: {:error, :not_authorized}
  defp require_completed(%{status: "completed"}), do: :ok
  defp require_completed(_source), do: {:error, :invalid_state}
  defp require_available(%{status: "available"}), do: :ok
  defp require_available(_entitlement), do: {:error, :used}

  defp validate_link(nil, _current_time), do: {:error, :invalid}

  defp validate_link(%Link{entitlement: entitlement} = link, current_time) do
    cond do
      link.invalidated_at || link.consumed_at || entitlement.status == "consumed" ->
        {:error, :used}

      not Plug.Crypto.secure_compare(link.attendee_hash, entitlement.attendee_hash) ->
        invalid(link)

      DateTime.compare(current_time, entitlement.not_before) == :lt ->
        {:error, :not_yet_open}

      DateTime.compare(current_time, entitlement.expires_at) == :gt ->
        {:error, :expired}

      true ->
        {:ok, entitlement, link}
    end
  end

  defp invalid(link) do
    link
    |> Link.changeset(%{invalid_attempt_count: link.invalid_attempt_count + 1})
    |> Repo.update()

    {:error, :invalid}
  end

  defp lock_entitlement(id) do
    from(entitlement in Entitlement,
      where: entitlement.id == ^id,
      lock: "FOR UPDATE",
      preload: [:source_meeting]
    )
    |> Repo.one()
  end

  defp lock_link(id, entitlement) do
    case from(link in Link, where: link.id == ^id, lock: "FOR UPDATE") |> Repo.one() do
      %Link{} = link -> %{link | entitlement: entitlement}
      nil -> nil
    end
  end

  defp validate_requested_time(starts_at, entitlement) do
    if DateTime.compare(starts_at, entitlement.not_before) in [:eq, :gt] and
         DateTime.compare(starts_at, entitlement.expires_at) in [:eq, :lt] do
      :ok
    else
      {:error, :slot_unavailable}
    end
  end

  defp fresh_calendar_check(source, starts_at) do
    CalendarAvailability.final_check(%{
      start_datetime: starts_at,
      end_datetime: DateTime.add(starts_at, 30, :minute),
      date: DateTime.to_date(starts_at),
      organizer_user_id: source.organizer_user_id,
      buffer_minutes: 0
    })
  end

  defp create_child(source, starts_at) do
    Scheduling.create_meeting_with_conflict_check(
      %{
        uid: UUID.uuid4(),
        title: "Included follow-up",
        start_time: starts_at,
        end_time: DateTime.add(starts_at, 30, :minute),
        duration: 30,
        organizer_name: source.organizer_name,
        organizer_email: source.organizer_email,
        organizer_user_id: source.organizer_user_id,
        attendee_name: source.attendee_name,
        attendee_email: source.attendee_email,
        attendee_timezone: source.attendee_timezone,
        attendee_locale: source.attendee_locale,
        calendar_integration_id: source.calendar_integration_id,
        calendar_path: source.calendar_path,
        video_integration_id: source.video_integration_id,
        meeting_type: "follow-up",
        status: "confirmed",
        service_snapshot: @snapshot,
        custom_fields_snapshot: [],
        custom_field_answers: %{}
      },
      enforce_booking_limits: false
    )
  end

  defp consume_entitlement(entitlement, child, current_time) do
    entitlement
    |> Entitlement.changeset(%{
      status: "consumed",
      redeemed_meeting_id: child.id,
      consumed_at: current_time
    })
    |> Repo.update()
  end

  defp consume_link(link, current_time) do
    link |> Link.changeset(%{consumed_at: current_time}) |> Repo.update()
  end

  defp now, do: Clock.utc_now() |> DateTime.truncate(:second)
end
