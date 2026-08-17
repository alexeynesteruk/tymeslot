defmodule TymeslotWeb.Live.Scheduling.BookingSubmissionHandlerComponentTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MyPawTrainer.Intake
  alias TymeslotWeb.Live.Scheduling.BookingConfig
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine

  @forbidden_ids ~w(phone meeting_mode meeting-mode service_mode)

  test "uses discovery intake for discovery-call and maps form name and email" do
    socket = mpt_socket("discovery-call", %{"main_question" => "How can I help Milo?"})

    assert {:ok, snapshot, normalized} =
             BookingSubmissionHandlerComponent.validate_booking_answers(socket, %{
               "name" => "Alex",
               "email" => "alex@example.com"
             })

    assert Enum.any?(snapshot, &(&1["id"] == "main_question"))
    assert normalized["client_name"] == "Alex"
    assert normalized["email"] == "alex@example.com"
    assert normalized["main_question"] == "How can I help Milo?"
    refute Enum.any?(snapshot, &(&1["id"] in @forbidden_ids))
  end

  test "uses full intake for online-consultation" do
    socket = mpt_socket("online-consultation", %{})

    assert {:error, errors} =
             BookingSubmissionHandlerComponent.validate_booking_answers(socket, %{
               "name" => "Alex",
               "email" => "alex@example.com"
             })

    assert Map.has_key?(errors, "dog_name")
    assert Map.has_key?(errors, "main_concern")
    refute Map.has_key?(errors, "phone")
  end

  test "rejects extra keys on My Paw Trainer services instead of host custom fields" do
    host_field = [
      %{"id" => "company", "type" => "short_text", "label" => "Company", "required" => true}
    ]

    socket =
      mpt_socket(
        "discovery-call",
        %{"main_question" => "How can I help Milo?", "company" => "Acme", "phone" => "555-0100"},
        host_field
      )

    assert {:error, errors} =
             BookingSubmissionHandlerComponent.validate_booking_answers(socket, %{
               "name" => "Alex",
               "email" => "alex@example.com"
             })

    assert Map.has_key?(errors, "phone")
    assert Map.has_key?(errors, "company")
    refute Map.has_key?(errors, "client_name")
  end

  test "generic meeting types still use existing custom fields and drop extra keys" do
    snapshot = [
      %{"id" => "company", "type" => "short_text", "label" => "Company", "required" => true}
    ]

    engine = %{Engine.init(snapshot) | answers: %{"company" => "Acme", "phone" => "555-0100"}}

    socket = %Socket{
      assigns: %{__changed__: %{}, meeting_type: %{name: "Chat"}, engine: engine}
    }

    assert {:ok, ^snapshot, normalized} =
             BookingSubmissionHandlerComponent.validate_booking_answers(socket, %{
               "name" => "Alex",
               "email" => "alex@example.com"
             })

    assert normalized == %{"company" => "Acme"}
    refute Map.has_key?(normalized, "phone")
  end

  test "booking config and MPT snapshots introduce no phone or meeting-mode fields" do
    names = Enum.map(BookingConfig.booking_field_spec(), &elem(&1, 0))
    refute "phone" in names
    refute "meeting_mode" in names
    refute "meeting-mode" in names

    assert BookingConfig.booking_field_spec("discovery-call") ==
             BookingConfig.booking_field_spec()

    assert BookingConfig.booking_field_spec("online-consultation") ==
             BookingConfig.booking_field_spec()

    for service_id <- ~w(discovery-call online-consultation in-home-consultation) do
      ids = Enum.map(Intake.snapshot_for(service_id), & &1["id"])
      refute Enum.any?(@forbidden_ids, &(&1 in ids))
    end
  end

  defp mpt_socket(service_id, answers, definitions \\ []) do
    engine = %{Engine.init(definitions) | answers: answers}

    %Socket{
      assigns: %{
        __changed__: %{},
        meeting_type: %{service_id: service_id},
        engine: engine
      }
    }
  end
end
