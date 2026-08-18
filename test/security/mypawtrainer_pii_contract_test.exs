defmodule Tymeslot.Security.MyPawTrainerPIIContractTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Analytics.Contract

  @sensitive %{
    attendee_name: "Client Person",
    attendee_email: "client@example.com",
    attendee_phone: "+1 904 555 0100",
    dog_name: "Pepper",
    zip_code: "32084",
    main_concern: "Growling near food",
    brief_context: "Started after moving",
    desired_result: "Calmer meals",
    setup_intent: "seti_private",
    payment_method: "pm_private",
    card: "4242 4242 4242 4242"
  }

  test "logger metadata retains operational fields and redacts intake and payment details" do
    event = %{
      level: :info,
      msg: {:string, "booking"},
      meta:
        Map.merge(@sensitive, %{
          booking_id: "booking-1",
          payment_id: "payment-1",
          service_id: "online-consultation",
          status: "confirmed",
          error_category: "transport",
          occurred_at: ~U[2026-08-17 12:00:00Z]
        })
    }

    filtered = MetadataRedactor.filter(event, [])

    Enum.each(Map.keys(@sensitive), fn key ->
      assert filtered.meta[key] == "[REDACTED]"
    end)

    assert filtered.meta.booking_id == "booking-1"
    assert filtered.meta.payment_id == "payment-1"
    assert filtered.meta.service_id == "online-consultation"
    assert filtered.meta.status == "confirmed"
    assert filtered.meta.error_category == "transport"
    assert filtered.meta.occurred_at == ~U[2026-08-17 12:00:00Z]
  end

  test "nested logger and alert context cannot bypass the private-field denylist" do
    event = %{
      level: :error,
      msg: {:string, "booking failed"},
      meta: %{context: %{request: @sensitive}, booking_id: "booking-1"}
    }

    filtered = MetadataRedactor.filter(event, [])
    alert = PIIScrubber.scrub(%{context: %{request: @sensitive}, booking_id: "booking-1"})

    for value <- Map.values(@sensitive) do
      refute inspect(filtered.meta) =~ value
      refute inspect(alert) =~ value
    end

    assert filtered.meta.booking_id == "booking-1"
    assert alert.booking_id == "booking-1"
  end

  test "message and admin-alert scrubbers remove named intake and card-like values" do
    inspected = inspect(@sensitive)
    redacted = Redactor.redact(inspected)
    alert = PIIScrubber.scrub(@sensitive)

    for value <- Map.values(@sensitive) do
      refute redacted =~ value
      refute inspect(alert) =~ value
    end

    assert Map.keys(alert) == []
  end

  test "public routes never encode intake field names" do
    forbidden = Map.keys(@sensitive) |> Enum.map(&Atom.to_string/1)

    paths =
      TymeslotWeb.Router.__routes__()
      |> Enum.map(& &1.path)

    Enum.each(paths, fn path ->
      Enum.each(forbidden, fn field -> refute path =~ field end)
    end)
  end

  test "analytics rejects intake and attendee identity fields" do
    forbidden = Map.keys(@sensitive)

    Enum.each(forbidden, fn field ->
      assert_raise ArgumentError, fn ->
        Contract.validate_with!("booking_contract", %{field => "private"}, %{
          "booking_contract" => [field]
        })
      end
    end)
  end
end
