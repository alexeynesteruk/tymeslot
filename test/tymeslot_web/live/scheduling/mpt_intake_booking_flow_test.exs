defmodule TymeslotWeb.Live.Scheduling.MptIntakeBookingFlowTest do
  @moduledoc """
  LiveView coverage for My Paw Trainer intake questions.

  Discovery meeting types have no host custom fields. The questions step
  must still render intake fields, accept answers, reach booking, and
  keep those answers after back-navigation.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()
    :ok
  end

  describe "discovery call" do
    setup do
      %{profile: bookable_profile("mpt-discovery", "discovery-call", 30, 4_900)}
    end

    @tag :capture_log
    test "discovery questions render, accept answers, reach booking, and survive back",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      html = render(view)
      text = html |> Floki.parse_document!() |> Floki.text()
      assert html =~ "Question 1 of 2"
      assert text =~ "Dog's name"
      refute html =~ "Enter Your Details"

      view
      |> form("form[phx-submit='next']", %{"value" => "Milo"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Question 2 of 2"
      assert render(view) =~ "One main question"

      view
      |> form("form[phx-submit='next']", %{"value" => "How can I make walks easier?"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Enter Your Details"

      view |> element("button[data-testid='back-step']") |> render_click()

      html = render(view)
      assert html =~ "One main question"
      assert html =~ "How can I make walks easier?"
      refute html =~ "Enter Your Details"
    end
  end

  describe "online consultation" do
    setup do
      %{profile: bookable_profile("mpt-online", "online-consultation", 90, 14_000)}
    end

    @tag :capture_log
    test "numeric age without a unit stays on questions and shows the unit error",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      assert render(view) =~ "Question 1 of 12"

      answers = %{
        "dog_name" => "Milo",
        "breed_or_mix" => "unknown",
        "dog_age" => "3",
        "dog_sex" => "male",
        "spay_neuter_status" => "yes",
        "origin" => "rescue_shelter",
        "acquisition_age" => "8",
        "acquisition_age_unit" => "months",
        "main_concern" => "Pulling on leash",
        "brief_context" => "Walks have become hard",
        "desired_result" => "Calmer walks"
      }

      Enum.each(answers, fn {id, value} ->
        send(view.pid, {:step_event, :questions, :answer, {id, value}})
      end)

      _drain = :sys.get_state(view.pid)

      for _index <- 1..12 do
        view |> element("button[phx-click='next'][phx-target]") |> render_click()
      end

      html = render(view)
      refute html =~ "Enter Your Details"
      assert html =~ "Age unit"
      assert html =~ "Choose weeks, months, or years"
    end
  end

  defp bookable_profile(username, service_id, duration_minutes, price_cents) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: username,
        booking_theme: "1",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    service = Tymeslot.MyPawTrainer.ServiceCatalog.fetch!(service_id)

    insert(:meeting_type,
      user: user,
      name: service.name,
      duration_minutes: duration_minutes,
      slug: service.route,
      service_id: service.id,
      service_price_cents: price_cents,
      service_currency: "usd",
      event_type_version: 1,
      is_active: true,
      custom_fields: []
    )

    profile
  end
end
