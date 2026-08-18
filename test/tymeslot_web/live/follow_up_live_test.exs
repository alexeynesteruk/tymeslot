defmodule TymeslotWeb.FollowUpLiveTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Meetings.Completion
  alias Tymeslot.MyPawTrainer.FollowUps
  alias Tymeslot.TestMocks

  @snapshot %{
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

  test "invalid links render a generic non-enumerating state", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/follow-up/not-a-token")
    html = render(view)
    assert html =~ "This follow-up link is unavailable"
    refute html =~ "not-a-token"
    refute html =~ "does not exist"
  end

  test "valid page shows only included follow-up details and minimum booking fields", %{
    conn: conn
  } do
    {_source, raw} = follow_up_link()

    assert {:ok, _view, html} = live(conn, "/follow-up/#{raw}")
    assert html =~ "Included follow-up"
    assert html =~ "30-minute virtual appointment"
    assert html =~ "name=\"follow_up[date]\""
    assert html =~ "name=\"follow_up[time]\""
    refute html =~ "intake"
    refute html =~ "payment"
    refute html =~ "card"
    refute html =~ "ZIP"
    refute html =~ "phone"
  end

  test "valid form books once and then renders the used state", %{conn: conn} do
    {source, raw} = follow_up_link()
    starts_at = DateTime.add(source.start_time, 6, :day)
    date = DateTime.to_date(starts_at) |> Date.to_iso8601()
    time = starts_at |> DateTime.to_time() |> Time.to_iso8601()

    {:ok, view, _html} = live(conn, "/follow-up/#{raw}")

    html =
      view
      |> form("#follow-up-form", %{"follow_up" => %{"date" => date, "time" => time}})
      |> render_submit()

    assert html =~ "Your follow-up is booked"
    assert html =~ "mypawtrainer@gmail.com"

    assert {:ok, _used_view, used_html} = live(conn, "/follow-up/#{raw}")
    assert used_html =~ "This follow-up link has already been used"
  end

  defp follow_up_link do
    owner = insert(:user)

    source =
      insert(:meeting,
        organizer_user_id: owner.id,
        status: "confirmed",
        start_time: ~U[2026-08-10 14:00:00Z],
        end_time: ~U[2026-08-10 15:30:00Z],
        attendee_timezone: "Etc/UTC",
        attendee_name: "Client",
        attendee_email: "client@example.com",
        service_snapshot: @snapshot
      )

    assert {:ok, _completed} = Completion.complete(source.id, owner.id)
    assert {:ok, raw, _link} = FollowUps.issue_link(source.id, owner.id)
    {source, raw}
  end
end
