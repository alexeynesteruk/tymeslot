defmodule TymeslotWeb.Dashboard.CalendarGrid.InitialStateTest do
  use ExUnit.Case, async: true

  alias TymeslotWeb.Dashboard.CalendarGrid.InitialState

  describe "today_in_timezone/2" do
    test "uses the local date when it differs from the UTC date" do
      assert InitialState.today_in_timezone(
               "Europe/Tallinn",
               ~U[2026-08-16 22:30:00Z]
             ) == ~D[2026-08-17]
    end

    test "falls back to the UTC date for an invalid timezone" do
      assert InitialState.today_in_timezone(
               "Not/A_Real_Zone",
               ~U[2026-08-16 22:30:00Z]
             ) == ~D[2026-08-16]
    end
  end
end
