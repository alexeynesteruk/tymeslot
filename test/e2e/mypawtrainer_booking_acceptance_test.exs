defmodule Tymeslot.E2E.MyPawTrainerBookingAcceptanceTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.SetupIntentSucceeded
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MyPawTrainer.Intake
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.MyPawTrainer.ZipAllowlist
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  @direct_services [
    {"discovery-call", 30, 4_900, :discovery},
    {"online-consultation", 90, 14_000, :full},
    {"in-home-consultation", 90, 19_000, :full}
  ]

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 0
    )

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _owner_id, _start, _end ->
      {:ok, []}
    end)

    owner = insert(:user, email: "host@example.com", name: "Anna")
    {:ok, profile} = Profiles.get_or_create_profile(owner.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{timezone: "America/New_York"})

    insert(:connect_account,
      user: owner,
      stripe_account_id: "acct_TEST",
      default_currency: "usd",
      charges_enabled: true
    )

    event_types =
      Map.new(@direct_services, fn {service_id, _duration, _price, _intake} ->
        service = ServiceCatalog.fetch!(service_id)

        event_type =
          insert(:meeting_type,
            user: owner,
            name: service.name,
            slug: service.route,
            duration_minutes: service.duration_minutes,
            is_active: true,
            payment_required: true,
            payment_timing: "deferred",
            price_cents: service.initial_price_cents,
            service_id: service.id,
            service_price_cents: service.initial_price_cents,
            service_currency: "usd",
            event_type_version: 1
          )

        {service_id, event_type}
      end)

    assert {:ok, _zip} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    %{owner: owner, event_types: event_types}
  end

  test "all direct services preserve intake, snapshot price, and setup-only payment flow", %{
    owner: owner,
    event_types: event_types
  } do
    for {{service_id, duration, price_cents, intake_kind}, index} <-
          Enum.with_index(@direct_services) do
      event_type = Map.fetch!(event_types, service_id)
      snapshot = Intake.question_snapshot_for(service_id)
      answers = answers_for(intake_kind)

      assert {:ok, normalized_answers} = Intake.validate_question_answers(service_id, answers)
      field_ids = Enum.map(snapshot, & &1["id"])
      refute Enum.any?(field_ids, &(&1 in ~w(phone meeting_mode meeting-mode service_mode)))

      if service_id == "in-home-consultation" do
        assert "zip" not in field_ids
      else
        refute Map.has_key?(meeting_params(owner, event_type, duration, service_id), :zip)
      end

      expect(StripeAdapterMock, :create_customer, fn params, opts ->
        assert opts[:connect_account] == "acct_TEST"
        assert params.email == "client@example.com"
        {:ok, %{"id" => "cus_test_#{String.replace(service_id, "-", "_")}"}}
      end)

      expect(StripeAdapterMock, :create_setup_checkout_session, fn params, opts ->
        assert opts[:connect_account] == "acct_TEST"
        assert params.mode == "setup"
        assert params.payment_method_types == ["card"]
        assert params.customer == "cus_test_#{String.replace(service_id, "-", "_")}"
        assert params.setup_intent_data.metadata.service_id == service_id
        refute Map.has_key?(params, :payment_intent_data)
        refute Map.has_key?(params, :line_items)
        refute Map.has_key?(params, :amount)

        suffix = String.replace(service_id, "-", "_")

        {:ok,
         %{
           id: "cs_test_#{suffix}",
           url: "https://checkout.stripe.test/cs_test_#{suffix}",
           setup_intent: %{id: "seti_test_#{suffix}"}
         }}
      end)

      params = %{
        form_data: %{
          "name" => "Test client",
          "email" => "client@example.com",
          "message" => ""
        },
        meeting_params:
          meeting_params(owner, event_type, duration, service_id, index)
          |> Map.put(:custom_fields_snapshot, snapshot)
          |> Map.put(:custom_field_answers, normalized_answers)
      }

      result = Orchestrator.submit_booking(params)
      assert {:ok, :payment_required, %{meeting: meeting}} = result

      assert meeting.duration == duration
      assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == duration
      assert meeting.custom_field_answers == normalized_answers
      assert is_nil(meeting.attendee_phone)
      assert meeting.service_snapshot["amount_cents"] == price_cents
      assert meeting.service_snapshot["duration_minutes"] == duration

      payment = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert payment.status == "setup_pending"
      assert payment.amount_cents == price_cents
      assert payment.stripe_customer_id == "cus_test_#{String.replace(service_id, "-", "_")}"
      assert is_nil(payment.stripe_payment_intent_id)
      assert is_nil(payment.stripe_charge_id)

      assert :ok = SetupIntentSucceeded.handle(setup_event(meeting, payment, service_id))
      assert Repo.reload!(payment).status == "card_saved"
      assert is_nil(Repo.reload!(payment).stripe_charge_id)
      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  test "fresh Google busy data rejects every direct service before Stripe", %{
    owner: owner,
    event_types: event_types
  } do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _owner_id, date, _end ->
      start_time = DateTime.new!(date, ~T[14:00:00], "America/New_York")
      {:ok, [%{start_time: start_time, end_time: DateTime.add(start_time, 6, :hour)}]}
    end)

    for {{service_id, duration, _price_cents, intake_kind}, index} <-
          Enum.with_index(@direct_services) do
      event_type = Map.fetch!(event_types, service_id)

      assert {:error, :slot_taken} =
               Orchestrator.submit_booking(%{
                 form_data: %{"name" => "Test client", "email" => "client@example.com"},
                 meeting_params:
                   meeting_params(owner, event_type, duration, service_id, index)
                   |> Map.put(:custom_fields_snapshot, Intake.question_snapshot_for(service_id))
                   |> Map.put(:custom_field_answers, answers_for(intake_kind))
               })
    end
  end

  defp meeting_params(owner, event_type, duration, service_id, index \\ 0) do
    %{
      date: Date.add(Date.utc_today(), 2),
      time: "#{14 + index * 2}:00",
      duration: duration,
      user_timezone: "America/New_York",
      organizer_user_id: owner.id,
      meeting_type_id: event_type.id
    }
    |> maybe_put_zip(service_id)
  end

  defp maybe_put_zip(params, "in-home-consultation"), do: Map.put(params, :zip, "32084")
  defp maybe_put_zip(params, _service_id), do: params

  defp answers_for(:discovery), do: %{"main_question" => "How can I help my dog settle?"}

  defp answers_for(:full) do
    %{
      "dog_name" => "Scout",
      "breed_or_mix" => "Mixed breed",
      "dog_age" => "3",
      "dog_age_unit" => "years",
      "dog_sex" => "female",
      "spay_neuter_status" => "yes",
      "origin" => "rescue_shelter",
      "acquisition_age" => "8",
      "acquisition_age_unit" => "months",
      "main_concern" => "Reactivity",
      "brief_context" => "Reacts to dogs on walks",
      "desired_result" => "Calmer neighborhood walks"
    }
  end

  defp setup_event(meeting, payment, service_id) do
    %{
      "id" => "evt_test_#{payment.id}",
      "type" => "setup_intent.succeeded",
      "account" => "acct_TEST",
      "data" => %{
        "object" => %{
          "id" => payment.stripe_setup_intent_id,
          "object" => "setup_intent",
          "status" => "succeeded",
          "customer" => "cus_test_#{meeting.id}",
          "payment_method" => "pm_test_#{meeting.id}",
          "metadata" => %{
            "booking_payment_id" => payment.id,
            "meeting_id" => meeting.id,
            "service_id" => service_id,
            "service_version" => "1"
          }
        }
      }
    }
  end
end
