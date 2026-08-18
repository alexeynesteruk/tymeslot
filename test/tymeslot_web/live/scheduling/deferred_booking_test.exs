defmodule TymeslotWeb.Live.Scheduling.DeferredBookingTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 0
    )

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "host@example.com", name: "Anna")
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{timezone: "America/New_York"})

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_HOST",
      default_currency: "usd",
      charges_enabled: true
    )

    service = ServiceCatalog.fetch!("discovery-call")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: service.name,
        duration_minutes: service.duration_minutes,
        is_active: true,
        payment_required: true,
        payment_timing: "deferred",
        price_cents: service.initial_price_cents,
        service_id: service.id,
        service_price_cents: service.initial_price_cents,
        service_currency: "usd",
        event_type_version: 1
      )

    %{user: user, meeting_type: meeting_type}
  end

  test "deferred booking creates setup checkout, holds awaiting_card, and does not charge",
       %{user: user, meeting_type: meeting_type} do
    expect(StripeAdapterMock, :create_customer, fn params, opts ->
      assert opts[:connect_account] == "acct_HOST"
      assert params.email == "guest@example.com"
      {:ok, %{"id" => "cus_DEFERRED"}}
    end)

    expect(StripeAdapterMock, :create_setup_checkout_session, fn params, opts ->
      assert opts[:connect_account] == "acct_HOST"
      assert params.mode == "setup"
      assert params.customer == "cus_DEFERRED"
      refute Map.has_key?(params, :payment_intent_data)
      refute Map.has_key?(params, :line_items)

      {:ok,
       %{
         id: "cs_DEFERRED",
         url: "https://checkout.stripe.com/cs_DEFERRED",
         setup_intent: %{id: "seti_DEFERRED"}
       }}
    end)

    params = %{
      form_data: %{
        "name" => "Guest",
        "email" => "guest@example.com",
        "message" => ""
      },
      meeting_params: %{
        date: Date.add(Date.utc_today(), 2),
        time: "14:00",
        duration: "30min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }
    }

    assert {:ok, :payment_required, %{meeting: meeting, checkout_url: url}} =
             Orchestrator.submit_booking(params)

    assert url =~ "cs_DEFERRED"
    assert meeting.status == "awaiting_card"
    assert meeting.service_snapshot["service_id"] == "discovery-call"
    assert meeting.service_snapshot["amount_cents"] == 4_900

    payment = BookingPaymentQueries.by_meeting_id(meeting.id)
    assert payment.status == "setup_pending"
    assert payment.payment_timing == "deferred"
    assert payment.amount_cents == 4_900
    assert payment.stripe_setup_intent_id == "seti_DEFERRED"
    assert is_nil(payment.stripe_charge_id)
    refute_enqueued(worker: EmailWorker)
  end
end
