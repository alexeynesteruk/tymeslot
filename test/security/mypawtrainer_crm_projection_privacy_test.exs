defmodule Tymeslot.Security.MyPawTrainerCrmProjectionPrivacyTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.CrmProjection

  @prohibited ~w(main_question main_concern brief_context desired_result safety bite zip phone stripe google token subscriber inquiry marketing_consent analytics utm email_body price payment_state card_state follow_up)

  test "payload and serialized request contain none of the prohibited data families" do
    meeting =
      insert(:meeting,
        attendee_message: "private concern",
        attendee_phone: "5550000000",
        custom_field_answers: %{"main_question" => "private", "zip" => "32084"},
        provider_event_id: "google-private",
        utm_source: "private-campaign",
        service_snapshot: %{
          "service_id" => "online-consultation",
          "service_name" => "Online behavior consultation",
          "delivery_mode" => "virtual",
          "amount_cents" => 14_000
        }
      )

    {:ok, {:ok, event}} = Repo.transaction(fn -> CrmProjection.append(meeting, "confirmed") end)
    serialized = Jason.encode!(event.payload) |> String.downcase()

    Enum.each(@prohibited, fn term -> refute serialized =~ term end)
    refute serialized =~ meeting.attendee_email
    refute serialized =~ meeting.attendee_name
    refute serialized =~ "private concern"
    refute serialized =~ "32084"
  end
end
