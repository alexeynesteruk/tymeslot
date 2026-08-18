defmodule Tymeslot.E2E.MyPawTrainerFollowUpAcceptanceTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.Completion
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MyPawTrainer.EventRoutes
  alias Tymeslot.MyPawTrainer.FollowUps
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _owner_id, _start, _end ->
      {:ok, []}
    end)

    :ok
  end

  test "consultation follow-up is private, single-use, 30 minutes, and payment-free" do
    owner = insert(:user)

    source =
      insert(:meeting,
        organizer_user_id: owner.id,
        status: "confirmed",
        start_time: ~U[2026-08-10 14:00:00Z],
        end_time: ~U[2026-08-10 15:30:00Z],
        attendee_timezone: "Etc/UTC",
        service_snapshot:
          ServiceCatalog.snapshot(%{
            service_id: "online-consultation",
            price_cents: 14_000,
            currency: "usd",
            version: 1
          })
      )

    assert {:ok, _completed} = Completion.complete(source.id, owner.id)
    assert {:ok, raw_token, _link} = FollowUps.issue_link(source.id, owner.id)
    starts_at = DateTime.add(source.start_time, 6, :day)

    assert {:ok, child} = FollowUps.redeem(raw_token, %{start_time: starts_at})
    assert child.duration == 30
    assert child.end_time == DateTime.add(starts_at, 30, :minute)
    assert child.service_snapshot["service_id"] == "follow-up"
    assert child.service_snapshot["amount_cents"] == 0
    assert child.service_snapshot["delivery_mode"] == "virtual"
    refute Repo.get_by(BookingPaymentSchema, meeting_id: child.id)
    assert {:error, :used} = FollowUps.redeem(raw_token, %{start_time: starts_at})
    assert {:error, :unknown_service} = EventRoutes.path("follow-up")
  end

  test "approval-first services cannot create meetings or payment records" do
    owner = insert(:user)

    for {service_id, price_cents} <- [
          {"online-case-management", 54_000},
          {"in-person-case-management", 69_000},
          {"assistant-dog-visit", 35_000}
        ] do
      event_type =
        insert(:meeting_type,
          user: owner,
          name: service_id,
          duration_minutes: 60,
          service_id: service_id,
          service_price_cents: price_cents,
          service_currency: "usd",
          event_type_version: 1,
          payment_required: true,
          payment_timing: "deferred",
          is_active: true
        )

      before_meetings = Repo.aggregate(Tymeslot.Meetings.MeetingSchema, :count)
      before_payments = Repo.aggregate(BookingPaymentSchema, :count)

      assert {:error, :service_not_bookable} =
               Create.execute(
                 %{
                   date: Date.add(Date.utc_today(), 2),
                   time: "14:00",
                   duration: 60,
                   user_timezone: "America/New_York",
                   organizer_user_id: owner.id,
                   meeting_type_id: event_type.id
                 },
                 %{"name" => "Test client", "email" => "client@example.test"}
               )

      assert Repo.aggregate(Tymeslot.Meetings.MeetingSchema, :count) == before_meetings
      assert Repo.aggregate(BookingPaymentSchema, :count) == before_payments
      assert {:error, :approval_first} = EventRoutes.path(service_id)
    end
  end

  test "each direct route becomes unavailable independently" do
    owner = insert(:user)

    event_types =
      Map.new(ServiceCatalog.direct_booking_ids(), fn service_id ->
        service = ServiceCatalog.fetch!(service_id)

        event_type =
          insert(:meeting_type,
            user: owner,
            name: service.name,
            slug: service.route,
            duration_minutes: service.duration_minutes,
            service_id: service.id,
            service_price_cents: service.initial_price_cents,
            service_currency: "usd",
            event_type_version: 1,
            is_active: true
          )

        {service_id, event_type}
      end)

    for disabled_id <- ServiceCatalog.direct_booking_ids() do
      disabled = event_types |> Map.fetch!(disabled_id) |> Repo.reload!()
      Repo.update!(Ecto.Changeset.change(disabled, is_active: false))

      assert {:error, :unavailable} = EventRoutes.resolve(owner.id, disabled_id)

      for active_id <- ServiceCatalog.direct_booking_ids() -- [disabled_id] do
        assert {:ok, %{path: path}} = EventRoutes.resolve(owner.id, active_id)
        assert {:ok, ^path} = EventRoutes.path(active_id)
      end

      disabled |> Repo.reload!() |> Ecto.Changeset.change(is_active: true) |> Repo.update!()
    end
  end
end
