defmodule Tymeslot.Integration.MyPawTrainerSameSlotBookingTest do
  use Tymeslot.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.UUID
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo

  @moduletag :database
  @moduletag :integration
  @moduletag :mpt_concurrency

  setup do
    cleanup_race_rows()
    on_exit(&cleanup_race_rows/0)
    :ok
  end

  test "two same-trainer creates of one empty slot yield one winner" do
    {user, start_time} = committed_trainer_and_slot()
    overlap_start = DateTime.add(start_time, 15, :minute)

    results =
      race([
        fn -> Scheduling.create_meeting_with_conflict_check(meeting_attrs(user, start_time)) end,
        fn ->
          Scheduling.create_meeting_with_conflict_check(meeting_attrs(user, overlap_start))
        end
      ])

    assert one_winner?(results),
           "expected one success and one time_conflict, got: #{inspect(results)}"

    assert overlapping_live_count(user.id, start_time, DateTime.add(overlap_start, 30, :minute)) ==
             1
  end

  test "a reschedule and a new booking cannot both take the same empty slot" do
    {user, occupied_start} = committed_trainer_and_slot()
    empty_start = DateTime.add(occupied_start, 2, :hour)
    overlap_start = DateTime.add(empty_start, 15, :minute)

    {:ok, existing} =
      Sandbox.unboxed_run(Repo, fn ->
        Scheduling.create_meeting_with_conflict_check(meeting_attrs(user, occupied_start))
      end)

    results =
      race([
        fn -> Scheduling.create_meeting_with_conflict_check(meeting_attrs(user, empty_start)) end,
        fn ->
          Scheduling.update_meeting_with_conflict_check(existing, %{
            start_time: overlap_start,
            end_time: DateTime.add(overlap_start, 30, :minute)
          })
        end
      ])

    assert one_winner?(results),
           "expected one success and one time_conflict, got: #{inspect(results)}"

    assert overlapping_live_count(
             user.id,
             empty_start,
             DateTime.add(overlap_start, 30, :minute)
           ) == 1
  end

  defp committed_trainer_and_slot do
    Sandbox.unboxed_run(Repo, fn ->
      unique = System.unique_integer([:positive])

      user = insert(:user, email: "race-#{unique}@example.com")

      profile =
        insert(:profile, user: user, timezone: "Etc/UTC", username: "race#{unique}")

      insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 0)

      start_time =
        DateTime.utc_now()
        |> DateTime.add(3, :day)
        |> DateTime.truncate(:second)
        |> Map.put(:minute, 0)
        |> Map.put(:second, 0)

      {user, start_time}
    end)
  end

  defp race(fun) when is_function(fun, 0) do
    race([fn -> fun.() end, fn -> fun.() end])
  end

  defp race(fun) when is_function(fun, 1) do
    race([fn -> fun.(:create) end, fn -> fun.(:reschedule) end])
  end

  defp race(funs) when is_list(funs) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, barrier, self()})

          receive do
            {:go, ^barrier} ->
              Sandbox.unboxed_run(Repo, fun)
          after
            5_000 -> {:error, :barrier_timeout}
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        receive do
          {:ready, ^barrier, pid} -> pid
        after
          5_000 -> flunk("racer did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, {:go, barrier}))
    Task.await_many(tasks, 15_000)
  end

  defp one_winner?(results) do
    successes = Enum.count(results, &match?({:ok, _}, &1))
    conflicts = Enum.count(results, &match?({:error, :time_conflict}, &1))
    successes == 1 and conflicts == 1
  end

  defp cleanup_race_rows do
    Sandbox.unboxed_run(Repo, fn ->
      import Ecto.Query

      meetings = Repo.all(from(m in MeetingSchema, where: m.title == "Same-slot race"))
      meeting_user_ids = Enum.map(meetings, & &1.organizer_user_id)

      race_user_ids =
        Repo.all(from(u in UserSchema, where: like(u.email, "race-%@example.com"), select: u.id))

      user_ids = Enum.uniq(meeting_user_ids ++ race_user_ids)

      Repo.delete_all(
        from(m in MeetingSchema,
          where: m.organizer_user_id in ^user_ids or m.title == "Same-slot race"
        )
      )

      Repo.delete_all(from(u in UserSchema, where: u.id in ^user_ids))
    end)
  end

  defp overlapping_live_count(organizer_user_id, range_start, range_end) do
    Sandbox.unboxed_run(Repo, fn ->
      import Ecto.Query

      MeetingSchema
      |> where(
        [m],
        m.organizer_user_id == ^organizer_user_id and m.status == "confirmed" and
          m.start_time < ^range_end and m.end_time > ^range_start
      )
      |> Repo.aggregate(:count)
    end)
  end

  defp meeting_attrs(user, start_time) do
    %{
      uid: UUID.generate(),
      title: "Same-slot race",
      summary: "Same-slot race",
      description: "",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      organizer_user_id: user.id,
      organizer_name: "Organiser",
      organizer_email: "organiser-#{user.id}@example.com",
      attendee_name: "Attendee",
      attendee_email: "attendee-#{System.unique_integer([:positive])}@example.com",
      attendee_timezone: "Etc/UTC",
      attendee_locale: "en",
      status: "confirmed"
    }
  end
end
