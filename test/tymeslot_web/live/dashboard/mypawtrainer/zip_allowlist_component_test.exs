defmodule TymeslotWeb.Live.Dashboard.Mypawtrainer.ZipAllowlistComponentTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :live

  import Ecto.Query
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MyPawTrainer.ZipAllowlist
  alias Tymeslot.MyPawTrainer.ZipAllowlistAuditSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})
    ctx
  end

  test "authenticated owner can add, deactivate, and reactivate a ZIP", %{
    conn: conn,
    user: user
  } do
    {:ok, view, html} = live(conn, ~p"/dashboard/service-area")

    assert html =~ "Service area"
    refute html =~ "32084"

    view
    |> form("form[phx-submit='add_zip']", %{zip_code: "32084"})
    |> render_submit()

    assert render(view) =~ "32084"
    assert ZipAllowlist.eligible?(user.id, "32084")

    view
    |> element("button[phx-click='deactivate_zip'][phx-value-zip='32084']")
    |> render_click()

    refute ZipAllowlist.eligible?(user.id, "32084")
    assert render(view) =~ "Inactive"

    view
    |> element("button[phx-click='reactivate_zip'][phx-value-zip='32084']")
    |> render_click()

    assert ZipAllowlist.eligible?(user.id, "32084")

    actions =
      Repo.all(from(a in ZipAllowlistAuditSchema, order_by: [asc: a.id], select: a.action))

    assert actions == ["add", "deactivate", "reactivate"]
  end

  test "the dashboard page never lists another owner's ZIPs", %{conn: conn, user: user} do
    other = insert(:user)

    assert {:ok, _row} =
             ZipAllowlist.set_active(other.id, "99999", active: true, actor_id: other.id)

    {:ok, view, _html} = live(conn, ~p"/dashboard/service-area")

    refute has_element?(view, "td", "99999")
    refute ZipAllowlist.eligible?(user.id, "99999")
  end

  test "unauthenticated visitors cannot open the service-area page" do
    conn = build_conn()
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/dashboard/service-area")
    assert to =~ "/auth/login"
  end
end
