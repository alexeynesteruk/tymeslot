defmodule Tymeslot.MyPawTrainer.FollowUpsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.Completion
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MyPawTrainer.FollowUpEntitlementSchema
  alias Tymeslot.MyPawTrainer.FollowUpLinkSchema
  alias Tymeslot.MyPawTrainer.FollowUps
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  @online_snapshot %{
    "service_id" => "online-consultation",
    "service_name" => "Online behavior consultation",
    "amount_cents" => 14_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _owner_id, _from, _to ->
      {:ok, []}
    end)

    :ok
  end

  test "completion creates one timezone-aware entitlement for online and in-home consultations" do
    owner = insert(:user)

    for {service_id, mode} <- [
          {"online-consultation", "virtual"},
          {"in-home-consultation", "in_home"}
        ] do
      source =
        consultation(owner, service_id,
          delivery_mode: mode,
          start_time: ~U[2026-11-01 05:30:00Z],
          end_time: ~U[2026-11-01 07:00:00Z],
          attendee_timezone: "America/New_York"
        )

      assert {:ok, %{status: "completed"}} = Completion.complete(source.id, owner.id)

      entitlement = Repo.get_by!(FollowUpEntitlementSchema, source_meeting_id: source.id)
      assert entitlement.status == "available"
      assert entitlement.not_before == ~U[2026-11-06 05:00:00Z]
      assert entitlement.expires_at == ~U[2026-11-12 04:59:59Z]
      assert entitlement.meeting_timezone == "America/New_York"
      assert entitlement.owner_user_id == owner.id
    end
  end

  test "discovery completion does not create a follow-up entitlement" do
    owner = insert(:user)
    source = consultation(owner, "discovery-call")

    assert {:ok, _completed} = Completion.complete(source.id, owner.id)
    refute Repo.get_by(FollowUpEntitlementSchema, source_meeting_id: source.id)
  end

  test "link issue requires the owner, rotates the prior link, and never stores the raw token" do
    owner = insert(:user)
    source = completed_consultation(owner)
    other = insert(:user)

    assert {:error, :not_authorized} = FollowUps.issue_link(source.id, other.id)
    assert {:ok, first_raw, first} = FollowUps.issue_link(source.id, owner.id)
    assert first.delivered_at
    refute first.token_hash == first_raw

    assert {:ok, second_raw, second} = FollowUps.issue_link(source.id, owner.id)
    refute first_raw == second_raw
    assert Repo.get!(FollowUpLinkSchema, first.id).invalidated_at
    refute Repo.get!(FollowUpLinkSchema, second.id).invalidated_at
  end

  test "a valid link redeems once into a zero-dollar 30-minute virtual child on the same calendar" do
    owner = insert(:user)

    source =
      completed_consultation(owner,
        calendar_integration_id: insert(:calendar_integration, user: owner).id
      )

    {:ok, raw, _link} = FollowUps.issue_link(source.id, owner.id)
    starts_at = DateTime.add(source.start_time, 6, :day)

    assert {:ok, child} = FollowUps.redeem(raw, %{start_time: starts_at})
    assert child.end_time == DateTime.add(starts_at, 30, :minute)
    assert child.duration == 30
    assert child.status == "confirmed"
    assert child.calendar_integration_id == source.calendar_integration_id
    assert child.attendee_name == source.attendee_name
    assert child.attendee_email == source.attendee_email

    assert child.service_snapshot == %{
             "service_id" => "follow-up",
             "service_name" => "Included follow-up",
             "amount_cents" => 0,
             "duration_minutes" => 30,
             "currency" => "usd",
             "delivery_mode" => "virtual",
             "event_type_version" => 1
           }

    refute Repo.get_by(BookingPaymentSchema, meeting_id: child.id)
    assert_enqueued(worker: CalendarEventWorker)

    entitlement = Repo.get_by!(FollowUpEntitlementSchema, source_meeting_id: source.id)
    assert entitlement.status == "consumed"
    assert entitlement.redeemed_meeting_id == child.id

    assert {:error, :used} =
             FollowUps.redeem(raw, %{start_time: DateTime.add(starts_at, 1, :day)})

    assert Repo.aggregate(FollowUpEntitlementSchema, :count) == 1
  end

  test "failed redemption preserves the entitlement and allows a later retry" do
    owner = insert(:user)
    source = completed_consultation(owner)
    {:ok, raw, _link} = FollowUps.issue_link(source.id, owner.id)
    starts_at = DateTime.add(source.start_time, 6, :day)

    expect(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _owner_id, _from, _to ->
      {:error, :timeout}
    end)

    assert {:error, :slot_unavailable} = FollowUps.redeem(raw, %{start_time: starts_at})

    assert Repo.get_by!(FollowUpEntitlementSchema, source_meeting_id: source.id).status ==
             "available"

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _owner_id, _from, _to ->
      {:ok, []}
    end)

    assert {:ok, _child} = FollowUps.redeem(raw, %{start_time: starts_at})
  end

  test "resolve returns safe invalid, not-yet-open, expired, and used states" do
    owner = insert(:user)
    source = completed_consultation(owner)
    entitlement = Repo.get_by!(FollowUpEntitlementSchema, source_meeting_id: source.id)
    {:ok, raw, link} = FollowUps.issue_link(source.id, owner.id)

    assert {:error, :invalid} = FollowUps.resolve("not-a-token", now: entitlement.not_before)

    assert {:error, :not_yet_open} =
             FollowUps.resolve(raw, now: DateTime.add(entitlement.not_before, -1, :second))

    assert {:error, :expired} =
             FollowUps.resolve(raw, now: DateTime.add(entitlement.expires_at, 1, :second))

    Repo.update!(FollowUpLinkSchema.changeset(link, %{consumed_at: entitlement.not_before}))
    assert {:error, :used} = FollowUps.resolve(raw, now: entitlement.not_before)
  end

  test "follow-up stays outside the public six-service and normal booking paths" do
    assert length(ServiceCatalog.all()) == 6
    refute Enum.any?(ServiceCatalog.all(), &(&1.id == "follow-up"))
    refute "follow-up" in ServiceCatalog.direct_booking_ids()
    assert {:error, :unknown_service} = ServiceCatalog.validate_id("follow-up")

    owner = insert(:user)

    meeting_type =
      insert(:meeting_type,
        user: owner,
        service_id: "follow-up",
        name: "Included follow-up",
        duration_minutes: 30,
        is_active: true,
        payment_required: false,
        price_cents: 1,
        service_price_cents: 1,
        service_currency: "usd",
        event_type_version: 1
      )

    assert {:error, :service_not_bookable} =
             Create.execute(
               %{
                 date: Date.add(Date.utc_today(), 7),
                 time: "14:00",
                 duration: "30min",
                 user_timezone: "Etc/UTC",
                 organizer_user_id: owner.id,
                 meeting_type_id: meeting_type.id
               },
               %{"name" => "Client", "email" => "client@example.com"}
             )
  end

  test "the payment checkout entry point refuses an internal follow-up" do
    meeting = insert(:meeting, service_snapshot: %{"service_id" => "follow-up"})

    assert {:error, :payment_not_required} = CheckoutSessions.create_session_for_booking(meeting)
    refute Repo.get_by(BookingPaymentSchema, meeting_id: meeting.id)
  end

  defp completed_consultation(owner, attrs \\ []) do
    source = consultation(owner, "online-consultation", attrs)
    assert {:ok, _completed} = Completion.complete(source.id, owner.id)
    source
  end

  defp consultation(owner, service_id, attrs \\ []) do
    snapshot =
      @online_snapshot
      |> Map.put("service_id", service_id)
      |> Map.put("delivery_mode", Keyword.get(attrs, :delivery_mode, "virtual"))

    attrs = Keyword.drop(attrs, [:delivery_mode])

    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: owner.id,
          status: "confirmed",
          start_time: ~U[2026-08-10 14:00:00Z],
          end_time: ~U[2026-08-10 15:30:00Z],
          attendee_timezone: "America/New_York",
          attendee_name: "Client",
          attendee_email: "client@example.com",
          service_snapshot: snapshot
        ],
        attrs
      )
    )
  end
end
