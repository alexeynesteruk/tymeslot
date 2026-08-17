defmodule Tymeslot.MyPawTrainer.Intake do
  @moduledoc "Service-specific consultation intake over existing custom fields."

  alias Tymeslot.CustomFields
  alias Tymeslot.MyPawTrainer.Intake.Definitions
  alias Tymeslot.MyPawTrainer.Intake.Normalizer
  alias Tymeslot.MyPawTrainer.ServiceCatalog

  @discovery_required ~w(client_name email main_question)
  @discovery_optional ~w(dog_name)
  @full_required ~w(
    client_name email dog_name breed_or_mix dog_age dog_sex spay_neuter_status
    origin acquisition_age main_concern brief_context desired_result
  )
  @full_optional ~w(dog_age_unit acquisition_age_unit)

  @ids %{
    "discovery-call" => {@discovery_required, @discovery_optional},
    "online-consultation" => {@full_required, @full_optional},
    "in-home-consultation" => {@full_required, @full_optional}
  }

  @spec required_ids(String.t()) :: [String.t()]
  def required_ids(service_id), do: elem(fetch_ids!(service_id), 0)

  @spec optional_ids(String.t()) :: [String.t()]
  def optional_ids(service_id), do: elem(fetch_ids!(service_id), 1)

  @spec snapshot_for(String.t()) :: [map()]
  def snapshot_for(service_id), do: Definitions.for_service(direct_service!(service_id))

  @booking_form_ids ~w(client_name email)

  @spec question_snapshot_for(String.t()) :: [map()]
  def question_snapshot_for(service_id) do
    Enum.reject(snapshot_for(service_id), &(&1["id"] in @booking_form_ids))
  end

  @spec definitions_for_meeting_type(map()) :: [map()]
  def definitions_for_meeting_type(%{service_id: service_id} = meeting_type) do
    if ServiceCatalog.direct_bookable?(service_id) do
      question_snapshot_for(service_id)
    else
      CustomFields.snapshot_for(meeting_type)
    end
  end

  def definitions_for_meeting_type(meeting_type), do: CustomFields.snapshot_for(meeting_type)

  @spec validate(String.t(), map()) :: {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate(service_id, answers) when is_map(answers) do
    validate_snapshot(snapshot_for(service_id), answers)
  end

  @spec validate_question_answers(String.t(), map()) ::
          {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate_question_answers(service_id, answers) when is_map(answers) do
    validate_snapshot(question_snapshot_for(service_id), answers)
  end

  @spec validate_wizard_answers(map(), map()) ::
          {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate_wizard_answers(meeting_type, answers) when is_map(answers) do
    service_id = service_id(meeting_type)

    if ServiceCatalog.direct_bookable?(service_id) do
      validate_question_answers(service_id, answers)
    else
      CustomFields.validate_answers(CustomFields.snapshot_for(meeting_type), answers)
    end
  end

  defp validate_snapshot(snapshot, answers) do
    extra_errors = Normalizer.extra_key_errors(snapshot, answers)
    age_errors = Normalizer.age_errors(snapshot, answers)
    prepared_answers = Normalizer.prepare_answers(answers)

    case CustomFields.validate_answers(snapshot, prepared_answers) do
      {:ok, normalized} ->
        finish(normalized, extra_errors, age_errors)

      {:error, field_errors} ->
        {:error, field_errors |> Map.merge(extra_errors) |> Map.merge(age_errors)}
    end
  end

  defp service_id(%{service_id: id}), do: id
  defp service_id(%{"service_id" => id}), do: id
  defp service_id(_meeting_type), do: nil

  defp finish(normalized, extra_errors, age_errors) do
    errors = Map.merge(extra_errors, age_errors)

    if map_size(errors) == 0 do
      {:ok, normalized}
    else
      {:error, errors}
    end
  end

  defp fetch_ids!(service_id) do
    Map.get(@ids, direct_service!(service_id)) ||
      raise ArgumentError, "intake is not defined for #{inspect(service_id)}"
  end

  defp direct_service!(service_id) do
    if ServiceCatalog.direct_bookable?(service_id) do
      service_id
    else
      raise ArgumentError, "intake is not defined for #{inspect(service_id)}"
    end
  end
end
