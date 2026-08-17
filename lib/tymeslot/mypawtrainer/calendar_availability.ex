defmodule Tymeslot.MyPawTrainer.CalendarAvailability do
  @moduledoc """
  Fresh, fail-closed calendar check for My Paw Trainer direct bookings.

  Cached display availability is never authoritative. Timeout, transport
  failure, a malformed payload, or an incomplete busy set refuses the slot.
  """

  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents

  @type slot :: %{
          required(:start_datetime) => DateTime.t(),
          required(:end_datetime) => DateTime.t(),
          optional(:date) => Date.t(),
          optional(:organizer_user_id) => integer(),
          optional(:buffer_minutes) => non_neg_integer(),
          optional(atom()) => term()
        }

  @spec final_check(slot(), keyword()) ::
          :ok | {:error, :calendar_unverifiable | :slot_unavailable}
  def final_check(slot, opts \\ [])

  def final_check(slot, opts) when is_map(slot) and is_list(opts) do
    cond do
      Keyword.get(opts, :google_timeout) == true ->
        {:error, :calendar_unverifiable}

      Keyword.get(opts, :complete) == false ->
        {:error, :calendar_unverifiable}

      Keyword.has_key?(opts, :transport_error) ->
        {:error, :calendar_unverifiable}

      Keyword.get(opts, :busy) == true ->
        {:error, :slot_unavailable}

      Keyword.has_key?(opts, :events) ->
        check_events(slot, Keyword.fetch!(opts, :events))

      is_function(Keyword.get(opts, :fetcher), 1) ->
        fetch_and_check(slot, Keyword.fetch!(opts, :fetcher))

      true ->
        fetch_and_check(slot, &default_fetcher/1)
    end
  end

  def final_check(_slot, _opts), do: {:error, :calendar_unverifiable}

  defp fetch_and_check(slot, fetcher) do
    case fetcher.(slot) do
      {:ok, events} ->
        check_events(slot, events)

      {:error, _reason} ->
        {:error, :calendar_unverifiable}

      _other ->
        {:error, :calendar_unverifiable}
    end
  end

  defp check_events(_slot, events) when not is_list(events), do: {:error, :calendar_unverifiable}

  defp check_events(slot, events) do
    start_datetime = Map.fetch!(slot, :start_datetime)
    end_datetime = Map.fetch!(slot, :end_datetime)
    buffer_minutes = Map.get(slot, :buffer_minutes, 0)

    Validation.validate_no_conflicts(start_datetime, end_datetime, events, %{
      buffer_minutes: buffer_minutes
    })
  end

  defp default_fetcher(slot) do
    organizer_user_id = Map.get(slot, :organizer_user_id)
    date = slot_date(slot)

    if is_integer(organizer_user_id) and match?(%Date{}, date) do
      CalendarEvents.get_events_for_range_fresh(organizer_user_id, date, date)
    else
      {:error, :organizer_required}
    end
  end

  defp slot_date(%{date: %Date{} = date}), do: date
  defp slot_date(%{start_datetime: %DateTime{} = start}), do: DateTime.to_date(start)
  defp slot_date(_slot), do: nil
end
