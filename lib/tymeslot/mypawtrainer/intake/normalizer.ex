defmodule Tymeslot.MyPawTrainer.Intake.Normalizer do
  @moduledoc "Age number-or-unknown rules and extra-key rejection for consultation intake."

  @age_ids ~w(dog_age acquisition_age)
  @age_pairs [
    {"dog_age", "dog_age_unit"},
    {"acquisition_age", "acquisition_age_unit"}
  ]
  @age_units ~w(weeks months years)

  @spec extra_key_errors([map()], map()) :: %{String.t() => String.t()}
  def extra_key_errors(snapshot, answers) do
    allowed = MapSet.new(Enum.map(snapshot, & &1["id"]))

    answers
    |> Map.keys()
    |> Enum.reduce(%{}, fn key, acc ->
      if MapSet.member?(allowed, key) do
        acc
      else
        Map.put(acc, key, "is not an accepted field")
      end
    end)
  end

  @spec prepare_answers(map()) :: map()
  def prepare_answers(answers) do
    Enum.reduce(@age_ids, answers, fn id, acc ->
      case acc[id] do
        value when is_number(value) -> Map.put(acc, id, to_string(value))
        value when is_binary(value) -> Map.put(acc, id, String.trim(value))
        _other -> acc
      end
    end)
  end

  @spec age_errors([map()], map()) :: %{String.t() => String.t()}
  def age_errors(snapshot, answers) do
    ids = MapSet.new(Enum.map(snapshot, & &1["id"]))

    Enum.reduce(@age_pairs, %{}, fn {age_id, unit_id}, acc ->
      if MapSet.member?(ids, age_id) do
        put_age_error(acc, age_id, unit_id, answers)
      else
        acc
      end
    end)
  end

  defp put_age_error(acc, age_id, unit_id, answers) do
    value = answers[age_id]

    cond do
      value == "unknown" ->
        acc

      blank_age?(value) ->
        Map.put(acc, age_id, "is required")

      numeric_age?(value) and answers[unit_id] not in @age_units ->
        Map.put(acc, unit_id, "Choose weeks, months, or years")

      numeric_age?(value) ->
        acc

      true ->
        Map.put(acc, age_id, "must be a non-negative age or unknown")
    end
  end

  defp blank_age?(value) when value in [nil, ""], do: true
  defp blank_age?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_age?(_value), do: false

  defp numeric_age?(value) when is_number(value), do: value >= 0

  defp numeric_age?(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number >= 0
      _other -> false
    end
  end

  defp numeric_age?(_value), do: false
end
