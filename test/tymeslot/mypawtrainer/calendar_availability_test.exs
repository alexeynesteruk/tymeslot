defmodule Tymeslot.MyPawTrainer.CalendarAvailabilityTest do
  use ExUnit.Case, async: true

  alias Tymeslot.MyPawTrainer.CalendarAvailability

  @slot %{
    start_datetime: ~U[2026-09-01 14:00:00Z],
    end_datetime: ~U[2026-09-01 14:30:00Z],
    date: ~D[2026-09-01],
    organizer_user_id: 1,
    buffer_minutes: 0
  }

  test "timeout, transport error, and incomplete busy sets fail closed" do
    assert {:error, :calendar_unverifiable} =
             CalendarAvailability.final_check(@slot, google_timeout: true)

    assert {:error, :calendar_unverifiable} =
             CalendarAvailability.final_check(@slot, complete: false)

    assert {:error, :calendar_unverifiable} =
             CalendarAvailability.final_check(@slot, transport_error: :nxdomain)
  end

  test "a busy interval on the fresh set is unavailable" do
    assert {:error, :slot_unavailable} = CalendarAvailability.final_check(@slot, busy: true)
  end

  test "a complete empty busy set is available" do
    assert :ok = CalendarAvailability.final_check(@slot, events: [])
  end

  test "malformed provider results fail closed" do
    assert {:error, :calendar_unverifiable} =
             CalendarAvailability.final_check(@slot, events: :not_a_list)
  end

  test "an injected fetcher is the only source of busy times" do
    busy_event = %{
      start_time: @slot.start_datetime,
      end_time: @slot.end_datetime,
      status: "confirmed",
      transparency: "opaque"
    }

    assert {:error, :slot_unavailable} =
             CalendarAvailability.final_check(@slot,
               fetcher: fn _slot -> {:ok, [busy_event]} end
             )

    assert :ok =
             CalendarAvailability.final_check(@slot,
               fetcher: fn _slot -> {:ok, []} end
             )

    assert {:error, :calendar_unverifiable} =
             CalendarAvailability.final_check(@slot,
               fetcher: fn _slot -> {:error, :timeout} end
             )

    assert {:error, :calendar_unverifiable} =
             CalendarAvailability.final_check(@slot,
               fetcher: fn _slot -> {:error, :some_calendars_unavailable} end
             )
  end
end
