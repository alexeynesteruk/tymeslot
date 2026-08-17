defmodule Tymeslot.MyPawTrainer.Intake.Normalizer do
  @moduledoc "Age unknown handling and extra-key rejection for consultation intake."

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

  @spec prepare_snapshot([map()], map()) :: [map()]
  def prepare_snapshot(snapshot, answers) do
    Enum.map(snapshot, fn field ->
      if field["id"] in @age_ids and answers[field["id"]] == "unknown" do
        field
        |> Map.put("type", "short_text")
        |> Map.delete("min")
      else
        field
      end
    end)
  end

  @spec age_unit_errors(map()) :: %{String.t() => String.t()}
  def age_unit_errors(answers) do
    Enum.reduce(@age_pairs, %{}, fn {age_id, unit_id}, acc ->
      if numeric_age?(answers[age_id]) and answers[unit_id] not in @age_units do
        Map.put(acc, unit_id, "Choose weeks, months, or years")
      else
        acc
      end
    end)
  end

  defp numeric_age?(value) when is_number(value), do: value >= 0

  defp numeric_age?(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number >= 0
      _other -> false
    end
  end

  defp numeric_age?(_value), do: false
end
