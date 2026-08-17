defmodule Tymeslot.Bookings.CreateMptGuardTest do
  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  alias Tymeslot.Bookings.Create
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.MyPawTrainer.ZipAllowlist

  defmodule MockCalendar do
    use Agent

    @spec start_link() :: {:ok, pid()} | {:error, term()}
    def start_link do
      Agent.start_link(fn -> {:ok, []} end, name: __MODULE__)
    end

    @spec get_events_for_range_fresh(integer(), Date.t(), Date.t()) ::
            {:ok, list()} | {:error, term()}
    def get_events_for_range_fresh(_user_id, _start_date, _end_date) do
      Agent.get(__MODULE__, & &1)
    end

    @spec get_booking_integration_info(integer() | map()) :: {:ok, map()} | {:error, term()}
    def get_booking_integration_info(_context), do: {:error, :no_integration}

    @spec set_response(term()) :: :ok
    def set_response(response), do: Agent.update(__MODULE__, fn _state -> response end)

    @spec stop() :: :ok
    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        _pid ->
          try do
            Agent.stop(__MODULE__)
          catch
            :exit, _reason -> :ok
          end
      end
    end
  end

  setup do
    {:ok, _pid} = MockCalendar.start_link()
    original_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, MockCalendar)

    on_exit(fn ->
      MockCalendar.stop()

      if original_module do
        Application.put_env(:tymeslot, :calendar_module, original_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "America/New_York")

    insert(:availability_schedule,
      profile: profile,
      is_default: true,
      advance_booking_days: 30,
      min_advance_hours: 0,
      buffer_minutes: 0
    )

    %{user: user}
  end

  test "direct-service timeout fails closed", %{user: user} do
    meeting_type = insert_direct_service(user, "discovery-call")
    MockCalendar.set_response({:error, :timeout})

    assert {:error, :slot_taken} =
             Create.execute(meeting_params(user, meeting_type, 30), form_data())
  end

  test "approval-first services cannot be booked through Create", %{user: user} do
    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "One-month online case management",
        duration_minutes: 60,
        service_id: "online-case-management",
        service_price_cents: 54_000,
        service_currency: "usd",
        event_type_version: 1,
        is_active: true
      )

    assert {:error, :service_not_bookable} =
             Create.execute(meeting_params(user, meeting_type, 60), form_data())
  end

  test "in-home create requires an active ZIP", %{user: user} do
    meeting_type = insert_direct_service(user, "in-home-consultation")
    MockCalendar.set_response({:ok, []})

    assert {:error, :service_area_unavailable} =
             Create.execute(
               meeting_params(user, meeting_type, 90) |> Map.put(:zip, "32084"),
               form_data()
             )

    assert {:ok, _row} =
             ZipAllowlist.set_active(user.id, "32084", active: true, actor_id: user.id)

    assert {:ok, meeting} =
             Create.execute(
               meeting_params(user, meeting_type, 90) |> Map.put(:zip, "32084"),
               form_data()
             )

    assert meeting.service_snapshot["service_id"] == "in-home-consultation"
    assert meeting.duration == 90
  end

  test "direct create uses catalog duration and keeps the snapshot", %{user: user} do
    meeting_type = insert_direct_service(user, "online-consultation")
    MockCalendar.set_response({:ok, []})

    assert {:ok, meeting} =
             Create.execute(meeting_params(user, meeting_type, 90), form_data())

    assert meeting.duration == 90
    assert meeting.service_snapshot["amount_cents"] == 14_000
    assert meeting.service_snapshot["event_type_version"] == 1
  end

  defp insert_direct_service(user, service_id) do
    service = ServiceCatalog.fetch!(service_id)

    insert(:meeting_type,
      user: user,
      name: service.name,
      duration_minutes: service.duration_minutes,
      slug: service.route,
      service_id: service.id,
      service_price_cents: service.initial_price_cents,
      service_currency: "usd",
      event_type_version: 1,
      is_active: true
    )
  end

  defp meeting_params(user, meeting_type, duration) do
    %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: duration,
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }
  end

  defp form_data do
    %{
      "name" => "Test Attendee",
      "email" => "attendee@test.com"
    }
  end
end
