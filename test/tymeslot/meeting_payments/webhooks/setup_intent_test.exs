defmodule Tymeslot.MeetingPayments.Webhooks.SetupIntentTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.MeetingPayments.Webhooks.SetupIntentSetupFailed
  alias Tymeslot.MeetingPayments.Webhooks.SetupIntentSucceeded
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @snapshot %{
    "service_id" => "online-consultation",
    "service_name" => "Online behavior consultation",
    "amount_cents" => 14_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  describe "setup_intent.succeeded" do
    test "saves the card, confirms the meeting, and never charges" do
      {meeting, payment} = insert_deferred_payment(setup_intent_id: "seti_OK")

      assert :ok =
               SetupIntentSucceeded.handle(
                 setup_event("evt_SETI_OK", "seti_OK", payment, meeting)
               )

      reloaded = Repo.reload!(payment)
      assert reloaded.status == "card_saved"
      assert reloaded.stripe_setup_intent_id == "seti_OK"
      assert reloaded.stripe_payment_method_id == "pm_OK"
      assert reloaded.stripe_customer_id == "cus_OK"
      assert is_nil(reloaded.stripe_charge_id)
      assert is_nil(reloaded.paid_at)

      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
      assert_enqueued(worker: EmailWorker)
    end

    test "falls back to signed metadata and binds the SetupIntent only when unset" do
      {meeting, payment} = insert_deferred_payment(setup_intent_id: nil)

      assert :ok =
               SetupIntentSucceeded.handle(setup_event("evt_BIND", "seti_FAST", payment, meeting))

      reloaded = Repo.reload!(payment)
      assert reloaded.status == "card_saved"
      assert reloaded.stripe_setup_intent_id == "seti_FAST"
    end

    test "fails closed when the connected account or snapshot does not match" do
      {meeting, payment} = insert_deferred_payment(setup_intent_id: "seti_BOUND")

      event =
        setup_event("evt_MISMATCH", "seti_OTHER", payment, meeting)
        |> put_in(["account"], "acct_OTHER")

      assert {:error, :setup_intent_mismatch} = SetupIntentSucceeded.handle(event)

      reloaded = Repo.reload!(payment)
      assert reloaded.status == "setup_pending"
      assert reloaded.stripe_setup_intent_id == "seti_BOUND"

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert unchanged.status == "awaiting_card"
    end

    test "is a no-op when the card is already saved" do
      {meeting, payment} =
        insert_deferred_payment(setup_intent_id: "seti_REPLAY", status: "card_saved")

      Repo.update!(Ecto.Changeset.change(meeting, status: "confirmed"))

      assert :ok =
               SetupIntentSucceeded.handle(
                 setup_event("evt_REPLAY", "seti_REPLAY", payment, meeting)
               )

      assert Repo.reload!(payment).status == "card_saved"
      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
    end
  end

  describe "event ordering" do
    test "checkout.session.completed before setup_intent.succeeded converges on card_saved" do
      {meeting, payment} = insert_deferred_payment(setup_intent_id: nil, session_id: "cs_ORDER")

      assert :ok =
               CheckoutSessionCompleted.handle(
                 setup_completed_event("evt_CS_FIRST", "cs_ORDER", "seti_ORDER", payment, meeting)
               )

      assert Repo.reload!(payment).status == "card_saved"
      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"

      assert :ok =
               SetupIntentSucceeded.handle(
                 setup_event("evt_SETI_SECOND", "seti_ORDER", payment, meeting)
               )

      reloaded = Repo.reload!(payment)
      assert reloaded.status == "card_saved"
      assert reloaded.stripe_setup_intent_id == "seti_ORDER"
      {:ok, still_confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert still_confirmed.status == "confirmed"
    end

    test "checkout.session.expired does not regress a saved card" do
      {meeting, payment} =
        insert_deferred_payment(
          setup_intent_id: "seti_SAVED",
          session_id: "cs_LATE",
          status: "card_saved"
        )

      Repo.update!(Ecto.Changeset.change(meeting, status: "confirmed"))

      assert :ok =
               CheckoutSessionExpired.handle(expired_event("evt_LATE", "cs_LATE", meeting))

      assert Repo.reload!(payment).status == "card_saved"
      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
    end

    test "failed setup releases the slot when the card was never saved" do
      {meeting, payment} = insert_deferred_payment(setup_intent_id: "seti_FAIL")

      assert :ok =
               SetupIntentSetupFailed.handle(
                 setup_failed_event("evt_FAIL", "seti_FAIL", payment, meeting)
               )

      assert Repo.reload!(payment).status == "cancelled"
      {:ok, expired} = MeetingQueries.get_meeting(meeting.id)
      assert expired.status == "expired"
    end
  end

  defp insert_deferred_payment(opts) do
    user = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        status: "awaiting_card",
        service_snapshot: @snapshot
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        stripe_account_id: "acct_HOST",
        status: Keyword.get(opts, :status, "setup_pending"),
        payment_timing: "deferred",
        service_snapshot: @snapshot,
        amount_cents: 14_000,
        currency: "usd",
        stripe_checkout_session_id: Keyword.get(opts, :session_id, "cs_SETUP"),
        stripe_setup_intent_id: Keyword.get(opts, :setup_intent_id, "seti_SETUP")
      )

    {meeting, payment}
  end

  defp setup_event(event_id, setup_intent_id, payment, meeting) do
    %{
      "id" => event_id,
      "type" => "setup_intent.succeeded",
      "account" => "acct_HOST",
      "data" => %{
        "object" => %{
          "id" => setup_intent_id,
          "object" => "setup_intent",
          "customer" => "cus_OK",
          "payment_method" => "pm_OK",
          "metadata" => %{
            "meeting_id" => meeting.id,
            "booking_payment_id" => payment.id,
            "service_id" => "online-consultation",
            "service_version" => "1"
          }
        }
      }
    }
  end

  defp setup_failed_event(event_id, setup_intent_id, payment, meeting) do
    setup_event(event_id, setup_intent_id, payment, meeting)
    |> Map.put("type", "setup_intent.setup_failed")
    |> put_in(["data", "object", "customer"], nil)
    |> put_in(["data", "object", "payment_method"], nil)
  end

  defp setup_completed_event(event_id, session_id, setup_intent_id, payment, meeting) do
    %{
      "id" => event_id,
      "type" => "checkout.session.completed",
      "account" => "acct_HOST",
      "data" => %{
        "object" => %{
          "id" => session_id,
          "mode" => "setup",
          "setup_intent" => setup_intent_id,
          "client_reference_id" => meeting.id,
          "metadata" => %{"booking_payment_id" => payment.id}
        }
      }
    }
  end

  defp expired_event(event_id, session_id, meeting) do
    %{
      "id" => event_id,
      "type" => "checkout.session.expired",
      "account" => "acct_HOST",
      "data" => %{
        "object" => %{
          "id" => session_id,
          "mode" => "setup",
          "client_reference_id" => meeting.id
        }
      }
    }
  end
end
