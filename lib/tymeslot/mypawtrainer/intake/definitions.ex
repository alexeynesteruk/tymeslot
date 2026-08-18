defmodule Tymeslot.MyPawTrainer.Intake.Definitions do
  @moduledoc "Fixed custom-field snapshots for My Paw Trainer direct services."

  alias Tymeslot.MyPawTrainer.ServiceCatalog

  @sex_options [
    %{"key" => "female", "label" => "Female"},
    %{"key" => "male", "label" => "Male"},
    %{"key" => "intersex", "label" => "Intersex"},
    %{"key" => "unknown", "label" => "Unknown"}
  ]

  @spay_neuter_options [
    %{"key" => "yes", "label" => "Yes"},
    %{"key" => "no", "label" => "No"},
    %{"key" => "unknown", "label" => "Unknown"},
    %{"key" => "not_applicable", "label" => "Not applicable"}
  ]

  @origin_options [
    %{"key" => "rescue_shelter", "label" => "Rescue or shelter"},
    %{"key" => "breeder", "label" => "Breeder"},
    %{"key" => "private_rehome", "label" => "Private rehome"},
    %{"key" => "found_stray", "label" => "Found or stray"},
    %{"key" => "born_in_household", "label" => "Born in household"},
    %{"key" => "other", "label" => "Other"},
    %{"key" => "unknown", "label" => "Unknown"}
  ]

  @age_unit_options [
    %{"key" => "weeks", "label" => "Weeks"},
    %{"key" => "months", "label" => "Months"},
    %{"key" => "years", "label" => "Years"}
  ]

  @spec for_service(String.t()) :: [map()]
  def for_service(service_id) when is_binary(service_id) do
    unless ServiceCatalog.direct_bookable?(service_id) do
      raise ArgumentError, "intake is not defined for #{inspect(service_id)}"
    end

    case service_id do
      "discovery-call" -> discovery_fields()
      _full -> full_fields()
    end
  end

  def for_service(service_id) do
    raise ArgumentError, "intake is not defined for #{inspect(service_id)}"
  end

  defp discovery_fields do
    [
      short_text("client_name", "Your name", true),
      short_text("email", "Email", true),
      short_text("dog_name", "Dog's name", false, "about_the_dog", "About the dog"),
      short_text("main_question", "One main question", true, "about_the_dog", "About the dog")
    ]
  end

  defp full_fields do
    [
      short_text("client_name", "Your name", true),
      short_text("email", "Email", true),
      short_text("dog_name", "Dog's name", true, "about_the_dog", "About the dog"),
      short_text("breed_or_mix", "Breed or mix", true, "about_the_dog", "About the dog"),
      short_text("dog_age", "Dog's age", true, "age_and_health", "Age and health", "dog_age"),
      select(
        "dog_age_unit",
        "Age unit",
        false,
        @age_unit_options,
        "age_and_health",
        "Age and health",
        "dog_age"
      ),
      select("dog_sex", "Sex", true, @sex_options, "age_and_health", "Age and health"),
      select(
        "spay_neuter_status",
        "Spay or neuter status",
        true,
        @spay_neuter_options,
        "age_and_health",
        "Age and health"
      ),
      select(
        "origin",
        "Origin",
        true,
        @origin_options,
        "how_they_came_home",
        "How they came home"
      ),
      short_text(
        "acquisition_age",
        "Age when acquired",
        true,
        "how_they_came_home",
        "How they came home",
        "acquisition_age"
      ),
      select(
        "acquisition_age_unit",
        "Acquisition age unit",
        false,
        @age_unit_options,
        "how_they_came_home",
        "How they came home",
        "acquisition_age"
      ),
      short_text(
        "main_concern",
        "Main concern",
        true,
        "what_you_need",
        "What you want help with"
      ),
      short_text(
        "brief_context",
        "Brief context",
        true,
        "what_you_need",
        "What you want help with"
      ),
      short_text(
        "desired_result",
        "Desired result",
        true,
        "what_you_need",
        "What you want help with"
      )
    ]
  end

  defp short_text(id, label, required, group \\ nil, group_label \\ nil, row \\ nil) do
    field("short_text", id, label, required, group, group_label, row)
  end

  defp select(id, label, required, options, group, group_label, row \\ nil) do
    field("single_select", id, label, required, group, group_label, row)
    |> Map.put("options", options)
  end

  defp field(type, id, label, required, group, group_label, row) do
    %{
      "id" => id,
      "type" => type,
      "label" => label,
      "required" => required
    }
    |> maybe_put("group", group)
    |> maybe_put("group_label", group_label)
    |> maybe_put("row", row)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
