defmodule TymeslotWeb.Live.Scheduling.MptZipGateTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MyPawTrainer.ZipAllowlist
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

  @tag :capture_log
  test "in-home hides times until an active ZIP is submitted", %{conn: conn} do
    profile = bookable_profile("mpt-zip-in-home", "in-home-consultation", 90, 19_000)

    {:ok, view, html} = live(conn, ~p"/#{profile.username}/in-home-consultation")

    assert html =~ "Enter your ZIP code to see in-home times."
    refute has_element?(view, "button[data-testid='time-slot']")
    refute has_element?(view, "button[data-testid='calendar-day']")

    view
    |> form("form[phx-submit='submit_zip']", %{zip: "32084"})
    |> render_submit()

    assert has_element?(view, "[data-testid='service-area-unavailable']")
    refute has_element?(view, "button[data-testid='time-slot']")

    assert {:ok, _row} =
             ZipAllowlist.set_active(profile.user_id, "32084",
               active: true,
               actor_id: profile.user_id
             )

    view
    |> form("form[phx-submit='submit_zip']", %{zip: "32084"})
    |> render_submit()

    refute has_element?(view, "[data-testid='service-area-unavailable']")
    assert has_element?(view, "button[data-testid='calendar-day']")
  end

  @tag :capture_log
  test "discovery never asks for a ZIP or calls the allowlist", %{conn: conn} do
    profile = bookable_profile("mpt-zip-discovery", "discovery-call", 30, 4_900)

    {:ok, view, html} = live(conn, ~p"/#{profile.username}/discovery-call")

    refute html =~ "Enter your ZIP code to see in-home times."
    refute has_element?(view, "[data-testid='service-area-gate']")
    assert has_element?(view, "button[data-testid='calendar-day']")
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
