defmodule TymeslotWeb.Themes.ManagementLinkTest do
  use TymeslotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Bookings.ManagementTokens
  alias Tymeslot.Emails.Templates.{AppointmentConfirmation, AppointmentReminder}
  alias Tymeslot.Meetings.MeetingQueries

  setup do
    on_exit(fn -> Application.delete_env(:tymeslot, :mypawtrainer_reschedule_deadlines) end)
    :ok
  end

  test "private management route resolves by token and exposes rescheduling without cancellation",
       %{conn: conn} do
    %{profile: profile, meeting: meeting} = direct_meeting_fixture()
    configure_deadline(meeting.organizer_user_id)
    assert {:ok, raw_token, _token} = ManagementTokens.issue(meeting)

    assert {:ok, view, html} = live(conn, "/#{profile.username}/manage/#{raw_token}")
    assert html =~ "Reschedule Appointment"
    refute html =~ "Cancel Appointment"
    refute html =~ meeting.uid

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("button", "Choose New Time") |> render_click()

    assert to == "/#{profile.username}?management_token=#{raw_token}"
  end

  test "invalid and cross-booking tokens return the same generic response", %{conn: conn} do
    %{profile: profile, meeting: meeting} = direct_meeting_fixture()
    %{meeting: other_meeting} = direct_meeting_fixture()
    configure_deadline(meeting.organizer_user_id)
    assert {:ok, raw_token, _token} = ManagementTokens.issue(meeting)

    assert {:error, {:redirect, first}} = live(conn, "/#{profile.username}/manage/invalid-token")

    assert {:error, {:redirect, second}} =
             live(conn, "/#{profile.username}/manage/#{raw_token}-other")

    assert first.to == second.to
    refute inspect(first) =~ other_meeting.uid
  end

  test "legacy MPT cancellation route is request-only and never mutates", %{conn: conn} do
    %{profile: profile, meeting: meeting} = direct_meeting_fixture()

    assert {:ok, _view, html} = live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")
    assert html =~ "mypawtrainer@gmail.com"
    refute html =~ "Yes, Cancel Meeting"
    refute html =~ "cancel-meeting"

    assert {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
    assert unchanged.status == "confirmed"
  end

  test "legacy MPT UID reschedule route returns the generic invalid-link response", %{conn: conn} do
    %{profile: profile, meeting: meeting} = direct_meeting_fixture()

    assert {:error, {:redirect, redirect}} =
             live(conn, "/#{profile.username}/meeting/#{meeting.uid}/reschedule")

    assert redirect.to == "/"
    assert redirect.flash["error"] == "This management link is invalid or unavailable"
  end

  test "MPT attendee confirmation has one management URL and email-only cancellation copy" do
    details =
      Tymeslot.EmailTestHelpers.build_appointment_details(%{
        reschedule_url: "https://book.mypawtrainer.com/anna/manage/private-token",
        cancel_url: nil,
        service_id: "online-consultation"
      })

    email = AppointmentConfirmation.render(:attendee, details.attendee_email, details)

    assert email.html_body =~ details.reschedule_url
    assert email.text_body =~ details.reschedule_url
    assert email.html_body =~ "mypawtrainer@gmail.com"
    assert email.text_body =~ "mypawtrainer@gmail.com"
    refute email.html_body =~ "Cancel Appointment"
    refute email.text_body =~ "Cancel:"
  end

  test "MPT attendee reminder has no cancellation action" do
    details =
      Tymeslot.EmailTestHelpers.build_appointment_details(%{
        reschedule_url: "https://book.mypawtrainer.com/anna/manage/private-token",
        cancel_url: nil,
        service_id: "online-consultation"
      })

    email = AppointmentReminder.render(:attendee, details.attendee_email, details)

    assert email.html_body =~ details.reschedule_url
    assert email.html_body =~ "mypawtrainer@gmail.com"
    assert email.text_body =~ "mypawtrainer@gmail.com"
    refute email.html_body =~ ">Cancel<"
    refute email.text_body =~ "Cancel:"
  end

  defp direct_meeting_fixture do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "anna-#{System.unique_integer([:positive])}")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        duration: 90,
        service_snapshot: %{"service_id" => "online-consultation", "duration_minutes" => 90}
      )

    %{profile: profile, meeting: meeting}
  end

  defp configure_deadline(owner_id) do
    Application.put_env(:tymeslot, :mypawtrainer_reschedule_deadlines, %{owner_id => 0})
  end
end
