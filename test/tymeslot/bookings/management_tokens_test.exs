defmodule Tymeslot.Bookings.ManagementTokensTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Bookings.ManagementTokenSchema
  alias Tymeslot.Bookings.ManagementTokens
  alias Tymeslot.Repo

  setup do
    on_exit(fn -> Application.delete_env(:tymeslot, :mypawtrainer_reschedule_deadlines) end)
    :ok
  end

  test "issues a random raw token while storing only its hash for the meeting and attendee" do
    meeting = direct_meeting()
    configure_deadline(meeting.organizer_user_id, 24)

    assert {:ok, raw_token, token} = ManagementTokens.issue(meeting)
    assert is_binary(raw_token)
    assert byte_size(raw_token) >= 32
    refute token.token_hash == raw_token
    refute inspect(token) =~ raw_token
    assert token.meeting_id == meeting.id
    assert token.purpose == "reschedule"
    assert token.attendee_hash == attendee_hash(meeting.attendee_email)

    assert Repo.get_by!(ManagementTokenSchema, meeting_id: meeting.id).token_hash ==
             token.token_hash

    assert {:ok, second_raw, _second_token} = ManagementTokens.issue(meeting)
    refute second_raw == raw_token
  end

  test "resolves only the meeting and attendee bound to an active token" do
    meeting = direct_meeting()

    other_meeting =
      direct_meeting(
        organizer_user_id: meeting.organizer_user_id,
        start_time: DateTime.add(meeting.start_time, 1, :day),
        end_time: DateTime.add(meeting.end_time, 1, :day)
      )

    configure_deadline(meeting.organizer_user_id, 24)

    assert {:ok, raw_token, _token} = ManagementTokens.issue(meeting)
    assert {:ok, resolved, _token} = ManagementTokens.resolve(raw_token)
    assert resolved.id == meeting.id
    refute resolved.id == other_meeting.id

    assert {:error, :invalid_management_link} = ManagementTokens.resolve(raw_token <> "tampered")
  end

  test "fails closed when the owner deadline is unset or has passed" do
    meeting = direct_meeting(start_time: DateTime.add(DateTime.utc_now(), 2, :day))

    assert {:error, :deadline_not_configured} = ManagementTokens.issue(meeting)

    configure_deadline(meeting.organizer_user_id, 24)
    assert {:ok, raw_token, token} = ManagementTokens.issue(meeting)
    assert DateTime.compare(token.expires_at, meeting.start_time) == :lt

    assert {:error, :invalid_management_link} =
             ManagementTokens.resolve(raw_token, now: DateTime.add(token.expires_at, 1, :second))
  end

  test "consuming a token rotates it and the old token cannot be reused" do
    meeting = direct_meeting()
    configure_deadline(meeting.organizer_user_id, 24)

    assert {:ok, raw_token, _token} = ManagementTokens.issue(meeting)
    assert {:ok, replacement_raw, replacement} = ManagementTokens.consume_and_rotate(raw_token)

    refute replacement_raw == raw_token
    assert replacement.meeting_id == meeting.id
    assert {:error, :invalid_management_link} = ManagementTokens.resolve(raw_token)
    assert {:ok, resolved, _token} = ManagementTokens.resolve(replacement_raw)
    assert resolved.id == meeting.id
  end

  test "issuing a newer emailed token revokes every older active token for the meeting" do
    meeting = direct_meeting()
    configure_deadline(meeting.organizer_user_id, 24)

    assert {:ok, first_raw, _first} = ManagementTokens.issue(meeting)
    assert {:ok, second_raw, _second} = ManagementTokens.issue(meeting)

    assert {:error, :invalid_management_link} = ManagementTokens.resolve(first_raw)
    assert {:ok, resolved, _token} = ManagementTokens.resolve(second_raw)
    assert resolved.id == meeting.id
  end

  defp direct_meeting(attrs \\ []) do
    user = insert(:user)

    defaults = [
      organizer_user_id: user.id,
      start_time: DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second),
      end_time:
        DateTime.add(DateTime.utc_now(), 7, :day)
        |> DateTime.add(90, :minute)
        |> DateTime.truncate(:second),
      duration: 90,
      service_snapshot: %{"service_id" => "online-consultation", "duration_minutes" => 90}
    ]

    insert(:meeting, Keyword.merge(defaults, attrs))
  end

  defp configure_deadline(owner_id, hours) do
    Application.put_env(:tymeslot, :mypawtrainer_reschedule_deadlines, %{owner_id => hours})
  end

  defp attendee_hash(email),
    do: :crypto.hash(:sha256, email |> String.trim() |> String.downcase())
end
