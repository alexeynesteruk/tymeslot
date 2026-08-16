defmodule Tymeslot.Meetings.MeetingSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Ecto.{Changeset, UUID}
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @valid_base_attrs %{
    uid: "test-uid-123",
    title: "Test Meeting",
    start_time: ~U[2024-01-01 10:00:00Z],
    end_time: ~U[2024-01-01 11:00:00Z],
    organizer_name: "Test Organizer",
    organizer_email: "organizer@test.com",
    attendee_name: "Test Attendee",
    attendee_email: "attendee@test.com"
  }

  describe "custom_fields_snapshot and custom_field_answers" do
    test "custom_fields_snapshot defaults to empty list when omitted from the changeset" do
      cs = Meeting.changeset(%Meeting{}, @valid_base_attrs)

      assert cs.valid?
      assert Changeset.get_field(cs, :custom_fields_snapshot) == []
    end

    test "custom_field_answers defaults to empty map when omitted from the changeset" do
      cs = Meeting.changeset(%Meeting{}, @valid_base_attrs)

      assert cs.valid?
      assert Changeset.get_field(cs, :custom_field_answers) == %{}
    end

    test "changeset accepts a snapshot and answers map" do
      field_id = UUID.generate()
      snap = [%{"id" => field_id, "type" => "short_text", "label" => "Company"}]
      ans = %{field_id => "Acme"}

      attrs =
        Map.merge(@valid_base_attrs, %{
          custom_fields_snapshot: snap,
          custom_field_answers: ans
        })

      cs = Meeting.changeset(%Meeting{}, attrs)

      assert cs.valid?
      assert Changeset.get_field(cs, :custom_fields_snapshot) == snap
      assert Changeset.get_field(cs, :custom_field_answers) == ans
    end
  end

  describe "service_snapshot" do
    test "defaults to an empty map for existing generic meetings" do
      changeset = Meeting.changeset(%Meeting{}, @valid_base_attrs)
      assert Changeset.get_field(changeset, :service_snapshot) == %{}
    end

    test "persists a complete immutable booking-time snapshot" do
      snapshot = %{
        "service_id" => "online-consultation",
        "service_name" => "Online behavior consultation",
        "amount_cents" => 14_000,
        "currency" => "usd",
        "duration_minutes" => 90,
        "delivery_mode" => "virtual",
        "event_type_version" => 1
      }

      changeset =
        Meeting.changeset(%Meeting{}, Map.put(@valid_base_attrs, :service_snapshot, snapshot))

      assert changeset.valid?
      assert Changeset.get_field(changeset, :service_snapshot) == snapshot
    end

    test "does not allow an existing snapshot to be changed" do
      meeting = %Meeting{
        service_snapshot: %{"service_id" => "online-consultation", "amount_cents" => 14_000}
      }

      changeset =
        Meeting.changeset(
          meeting,
          Map.put(@valid_base_attrs, :service_snapshot, %{"amount_cents" => 19_000})
        )

      assert Changeset.get_field(changeset, :service_snapshot) == meeting.service_snapshot
    end
  end

  describe "direct-service booking snapshot" do
    alias Tymeslot.Meetings.Scheduling

    test "a meeting retains price and version after its event type changes" do
      owner = insert(:user)

      event_type =
        insert(:meeting_type,
          user: owner,
          name: "Online behavior consultation",
          duration_minutes: 90,
          service_id: "online-consultation",
          service_price_cents: 14_000,
          service_currency: "usd",
          event_type_version: 1
        )

      attrs =
        @valid_base_attrs
        |> Map.merge(%{
          uid: Ecto.UUID.generate(),
          start_time: DateTime.add(DateTime.utc_now(), 2, :day) |> DateTime.truncate(:second),
          end_time:
            DateTime.add(DateTime.utc_now(), 2, :day)
            |> DateTime.add(90, :minute)
            |> DateTime.truncate(:second),
          duration: 90,
          organizer_user_id: owner.id,
          meeting_type_id: event_type.id
        })

      assert {:ok, meeting} = Scheduling.create_meeting_with_conflict_check(attrs)

      assert meeting.service_snapshot == %{
               "service_id" => "online-consultation",
               "service_name" => "Online behavior consultation",
               "amount_cents" => 14_000,
               "currency" => "usd",
               "duration_minutes" => 90,
               "delivery_mode" => "virtual",
               "event_type_version" => 1
             }

      assert {:ok, _updated} =
               Tymeslot.MeetingTypes.MeetingTypeQueries.update_service_price(
                 event_type.id,
                 owner.id,
                 1,
                 15_000
               )

      assert Repo.reload(meeting).service_snapshot == meeting.service_snapshot
    end
  end

  describe "provider_event_id" do
    test "accepts an id at Google's 1024-character maximum" do
      attrs = Map.put(@valid_base_attrs, :provider_event_id, String.duplicate("a", 1024))

      cs = Meeting.changeset(%Meeting{}, attrs)

      assert cs.valid?
    end

    test "rejects an id longer than 1024 characters with a changeset error" do
      attrs = Map.put(@valid_base_attrs, :provider_event_id, String.duplicate("a", 1025))

      cs = Meeting.changeset(%Meeting{}, attrs)

      refute cs.valid?
      assert %{provider_event_id: [_message]} = errors_on(cs)
    end
  end

  describe "business logic" do
    test "prevents meetings with end time before start time" do
      attrs = %{
        uid: "test-uid-123",
        title: "Invalid Meeting",
        start_time: ~U[2024-01-01 11:00:00Z],
        end_time: ~U[2024-01-01 10:00:00Z],
        organizer_name: "Test Organizer",
        organizer_email: "organizer@test.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@test.com"
      }

      changeset = Meeting.changeset(%Meeting{}, attrs)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "calculates duration from start and end times" do
      attrs = %{
        uid: "test-uid-123",
        title: "Test Meeting",
        start_time: ~U[2024-01-01 10:00:00Z],
        end_time: ~U[2024-01-01 11:30:00Z],
        organizer_name: "Test Organizer",
        organizer_email: "organizer@test.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@test.com"
      }

      changeset = Meeting.changeset(%Meeting{}, attrs)
      assert changeset.changes.duration == 90
    end

    test "determines if meeting is currently happening" do
      now = DateTime.utc_now()
      start_time = DateTime.add(now, -30, :minute)
      end_time = DateTime.add(now, 30, :minute)

      meeting = %Meeting{start_time: start_time, end_time: end_time}
      assert Meeting.current?(meeting)
    end

    test "determines if meeting is in the future" do
      future_time = DateTime.add(DateTime.utc_now(), 1, :hour)
      meeting = %Meeting{start_time: future_time}
      assert Meeting.future?(meeting)
    end
  end

  describe "status enum" do
    test "accepts awaiting_payment" do
      changeset = Meeting.changeset(%Meeting{}, %{status: "awaiting_payment"})

      refute Map.has_key?(errors_on(changeset), :status)
    end

    test "accepts expired" do
      changeset = Meeting.changeset(%Meeting{}, %{status: "expired"})

      refute Map.has_key?(errors_on(changeset), :status)
    end

    test "rejects unknown status" do
      changeset = Meeting.changeset(%Meeting{}, %{status: "not_a_real_status"})

      assert "is invalid" in errors_on(changeset).status
    end
  end
end
