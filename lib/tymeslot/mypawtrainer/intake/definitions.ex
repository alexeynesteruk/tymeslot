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
      short_text("dog_name", "Dog's name", false),
      short_text("main_question", "One main question", true)
    ]
  end

  defp full_fields do
    [
      short_text("client_name", "Your name", true),
      short_text("email", "Email", true),
      short_text("dog_name", "Dog's name", true),
      short_text("breed_or_mix", "Breed or mix", true),
      short_text("dog_age", "Dog's age", true),
      select("dog_age_unit", "Age unit", false, @age_unit_options),
      select("dog_sex", "Sex", true, @sex_options),
      select("spay_neuter_status", "Spay or neuter status", true, @spay_neuter_options),
      select("origin", "Origin", true, @origin_options),
      short_text("acquisition_age", "Age when acquired", true),
      select("acquisition_age_unit", "Acquisition age unit", false, @age_unit_options),
      short_text("main_concern", "Main concern", true),
      short_text("brief_context", "Brief context", true),
      short_text("desired_result", "Desired result", true)
    ]
  end

  defp short_text(id, label, required) do
    %{"id" => id, "type" => "short_text", "label" => label, "required" => required}
  end

  defp select(id, label, required, options) do
    %{
      "id" => id,
      "type" => "single_select",
      "label" => label,
      "required" => required,
      "options" => options
    }
  end
end
