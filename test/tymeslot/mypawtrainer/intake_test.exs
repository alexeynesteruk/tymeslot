defmodule Tymeslot.MyPawTrainer.IntakeTest do
  use ExUnit.Case, async: true

  alias Tymeslot.MyPawTrainer.Intake
  alias Tymeslot.MyPawTrainer.Intake.Definitions

  @sex_keys ~w(female male intersex unknown)
  @spay_neuter_keys ~w(yes no unknown not_applicable)
  @origin_keys ~w(rescue_shelter breeder private_rehome found_stray born_in_household other unknown)
  @forbidden_ids ~w(phone meeting_mode meeting-mode service_mode)

  test "discovery requires name, email, and one main question" do
    assert Intake.required_ids("discovery-call") == ~w(client_name email main_question)
    assert Intake.optional_ids("discovery-call") == ~w(dog_name)
  end

  test "online and in-home consultations share the same full required IDs" do
    assert Intake.required_ids("online-consultation") == ~w(
      client_name email dog_name breed_or_mix dog_age dog_sex spay_neuter_status
      origin acquisition_age main_concern brief_context desired_result
    )

    assert Intake.required_ids("in-home-consultation") ==
             Intake.required_ids("online-consultation")
  end

  test "discovery does not require full-intake dog profile fields" do
    full_only = ~w(
      breed_or_mix dog_age dog_sex spay_neuter_status origin acquisition_age
      main_concern brief_context desired_result
    )

    refute Enum.any?(full_only, &(&1 in Intake.required_ids("discovery-call")))

    assert {:ok, normalized} = Intake.validate("discovery-call", valid_discovery())
    refute Map.has_key?(normalized, "dog_age")
    refute Map.has_key?(normalized, "main_concern")
  end

  test "intake snapshots have no phone or meeting-mode IDs" do
    for service_id <- ~w(discovery-call online-consultation in-home-consultation) do
      ids = snapshot_ids(service_id)
      refute Enum.any?(@forbidden_ids, &(&1 in ids))
    end
  end

  test "unknown and approval-first service IDs fail closed" do
    for service_id <-
          ~w(unknown online-case-management in-person-case-management assistant-dog-visit) do
      assert_raise ArgumentError, fn -> Intake.required_ids(service_id) end
      assert_raise ArgumentError, fn -> Intake.optional_ids(service_id) end
      assert_raise ArgumentError, fn -> Intake.snapshot_for(service_id) end
      assert_raise ArgumentError, fn -> Intake.question_snapshot_for(service_id) end
      assert_raise ArgumentError, fn -> Intake.validate(service_id, %{}) end
    end
  end

  test "question_snapshot_for excludes name and email from the booking wizard" do
    discovery = Intake.question_snapshot_for("discovery-call")
    discovery_ids = Enum.map(discovery, & &1["id"])

    refute "client_name" in discovery_ids
    refute "email" in discovery_ids
    assert "main_question" in discovery_ids
    assert "dog_name" in discovery_ids
    assert field(discovery, "dog_name")["required"] == false

    full = Intake.question_snapshot_for("online-consultation")
    full_ids = Enum.map(full, & &1["id"])

    refute "client_name" in full_ids
    refute "email" in full_ids
    assert "dog_name" in full_ids
    assert "breed_or_mix" in full_ids
    assert "dog_age" in full_ids
    assert "dog_sex" in full_ids
    assert "spay_neuter_status" in full_ids
    assert "origin" in full_ids
    assert "acquisition_age" in full_ids
    assert "main_concern" in full_ids
    assert "brief_context" in full_ids
    assert "desired_result" in full_ids

    assert Intake.question_snapshot_for("in-home-consultation") == full
  end

  test "definitions_for_meeting_type uses intake questions for MPT and host fields for generic types" do
    mpt = %{service_id: "online-consultation", custom_fields: []}
    mpt_ids = Enum.map(Intake.definitions_for_meeting_type(mpt), & &1["id"])

    refute "client_name" in mpt_ids
    refute "email" in mpt_ids
    assert "dog_name" in mpt_ids
    assert "main_concern" in mpt_ids

    host_field = %{
      "id" => "host_note",
      "type" => "short_text",
      "label" => "Note",
      "required" => false
    }

    generic = %{custom_fields: [host_field]}
    generic_ids = Enum.map(Intake.definitions_for_meeting_type(generic), & &1["id"])
    assert generic_ids == ["host_note"]

    empty_generic = %{custom_fields: []}
    assert Intake.definitions_for_meeting_type(empty_generic) == []
  end

  test "definitions include the approved sex, spay/neuter, and origin option maps" do
    snapshot = Definitions.for_service("online-consultation")

    assert field(snapshot, "dog_sex") == %{
             "id" => "dog_sex",
             "type" => "single_select",
             "required" => true,
             "label" => "Sex",
             "options" => [
               %{"key" => "female", "label" => "Female"},
               %{"key" => "male", "label" => "Male"},
               %{"key" => "intersex", "label" => "Intersex"},
               %{"key" => "unknown", "label" => "Unknown"}
             ]
           }

    assert field(snapshot, "spay_neuter_status")["options"] == [
             %{"key" => "yes", "label" => "Yes"},
             %{"key" => "no", "label" => "No"},
             %{"key" => "unknown", "label" => "Unknown"},
             %{"key" => "not_applicable", "label" => "Not applicable"}
           ]

    assert field(snapshot, "origin")["options"] == [
             %{"key" => "rescue_shelter", "label" => "Rescue or shelter"},
             %{"key" => "breeder", "label" => "Breeder"},
             %{"key" => "private_rehome", "label" => "Private rehome"},
             %{"key" => "found_stray", "label" => "Found or stray"},
             %{"key" => "born_in_household", "label" => "Born in household"},
             %{"key" => "other", "label" => "Other"},
             %{"key" => "unknown", "label" => "Unknown"}
           ]
  end

  test "accepts every approved sex, spay/neuter, and origin value" do
    for sex <- @sex_keys do
      assert {:ok, normalized} =
               Intake.validate("online-consultation", %{valid_full() | "dog_sex" => sex})

      assert normalized["dog_sex"] == sex
    end

    for status <- @spay_neuter_keys do
      assert {:ok, normalized} =
               Intake.validate("online-consultation", %{
                 valid_full()
                 | "spay_neuter_status" => status
               })

      assert normalized["spay_neuter_status"] == status
    end

    for origin <- @origin_keys do
      assert {:ok, normalized} =
               Intake.validate("online-consultation", %{valid_full() | "origin" => origin})

      assert normalized["origin"] == origin
    end
  end

  test "accepts a non-negative age plus unit or unknown" do
    assert {:ok, with_unit} = Intake.validate("online-consultation", valid_full())
    assert with_unit["dog_age"] == "3"
    assert with_unit["dog_age_unit"] == "years"
    assert with_unit["acquisition_age"] == "8"
    assert with_unit["acquisition_age_unit"] == "months"

    unknown_age =
      valid_full()
      |> Map.put("dog_age", "unknown")
      |> Map.delete("dog_age_unit")
      |> Map.put("acquisition_age", "unknown")
      |> Map.delete("acquisition_age_unit")

    assert {:ok, normalized} = Intake.validate("online-consultation", unknown_age)
    assert normalized["dog_age"] == "unknown"
    assert normalized["acquisition_age"] == "unknown"

    assert {:error, errors} =
             Intake.validate("online-consultation", %{valid_full() | "dog_age" => "-1"})

    assert Map.has_key?(errors, "dog_age")

    assert {:error, unit_errors} =
             Intake.validate(
               "online-consultation",
               valid_full() |> Map.delete("dog_age_unit")
             )

    assert Map.has_key?(unit_errors, "dog_age_unit")
  end

  test "rejects extra keys and preserves valid values after recoverable errors" do
    extra = Map.put(valid_discovery(), "phone", "555-0100")
    original = Map.get(extra, "client_name")

    assert {:error, errors} = Intake.validate("discovery-call", extra)
    assert Map.has_key?(errors, "phone")
    refute Map.has_key?(errors, "client_name")
    refute Map.has_key?(errors, "email")
    assert extra["client_name"] == original
    assert extra["main_question"] == "How can I make walks easier?"

    recoverable = Map.put(valid_discovery(), "main_question", "")
    assert {:error, field_errors} = Intake.validate("discovery-call", recoverable)
    assert Map.has_key?(field_errors, "main_question")
    refute Map.has_key?(field_errors, "client_name")
    assert recoverable["client_name"] == "Alex"
    assert recoverable["email"] == "alex@example.com"

    assert {:ok, _normalized} =
             Intake.validate(
               "discovery-call",
               Map.put(recoverable, "main_question", "How can I make walks easier?")
             )
  end

  test "in-home required IDs equal online and selected service determines delivery" do
    assert Intake.required_ids("in-home-consultation") ==
             Intake.required_ids("online-consultation")

    online_ids = snapshot_ids("online-consultation")
    in_home_ids = snapshot_ids("in-home-consultation")
    assert online_ids == in_home_ids
    refute "meeting_mode" in online_ids
    refute "meeting-mode" in in_home_ids
  end

  defp valid_discovery do
    %{
      "client_name" => "Alex",
      "email" => "alex@example.com",
      "main_question" => "How can I make walks easier?"
    }
  end

  defp valid_full do
    %{
      "client_name" => "Alex",
      "email" => "alex@example.com",
      "dog_name" => "Milo",
      "breed_or_mix" => "unknown",
      "dog_age" => "3",
      "dog_age_unit" => "years",
      "dog_sex" => "male",
      "spay_neuter_status" => "yes",
      "origin" => "rescue_shelter",
      "acquisition_age" => "8",
      "acquisition_age_unit" => "months",
      "main_concern" => "Pulling on leash",
      "brief_context" => "Walks have become hard",
      "desired_result" => "Calmer walks"
    }
  end

  defp snapshot_ids(service_id) do
    service_id
    |> Intake.snapshot_for()
    |> Enum.map(& &1["id"])
  end

  defp field(snapshot, id), do: Enum.find(snapshot, &(&1["id"] == id))
end
