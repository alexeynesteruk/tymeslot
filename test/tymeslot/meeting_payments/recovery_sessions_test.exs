defmodule Tymeslot.MeetingPayments.RecoverySessionsTest do
  use Tymeslot.DataCase, async: false

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.RecoverySessions
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingQueries

  @snapshot %{
    "service_id" => "in-home-consultation",
    "service_name" => "In-home behavior consultation",
    "amount_cents" => 19_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "in_home",
    "event_type_version" => 1
  }

  setup :verify_on_exit!
  setup :set_mox_from_context

  for status <- ["charge_failed", "action_required"] do
    test "creates exact immutable recovery checkout for #{status}" do
      %{host: host, payment: payment} = failed_payment(unquote(status))

      expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
        assert params.mode == "payment"
        assert is_binary(params.success_url) and params.success_url != ""
        assert is_binary(params.cancel_url) and params.cancel_url != ""
        assert hd(params.line_items).price_data.unit_amount == 19_000
        assert hd(params.line_items).price_data.currency == "usd"

        assert params.payment_intent_data.metadata == %{
                 booking_payment_id: payment.id,
                 meeting_id: payment.meeting_id,
                 service_id: "in-home-consultation",
                 charge_attempt: 1,
                 payment_purpose: "recovery"
               }

        assert opts[:connect_account] == "acct_HOST"
        assert opts[:idempotency_key] == "recovery:#{payment.id}:1"
        {:ok, %{id: "cs_RECOVERY", url: "https://checkout.stripe.test/recovery"}}
      end)

      assert {:ok, result} = RecoverySessions.create(payment.id, host.id)
      assert result.checkout_url == "https://checkout.stripe.test/recovery"
      assert BookingPaymentQueries.get(payment.id).stripe_recovery_session_id == "cs_RECOVERY"
    end
  end

  test "rejects foreign owners and non-failure states without Stripe" do
    %{payment: failed} = failed_payment("charge_failed")
    assert {:error, :not_authorized} = RecoverySessions.create(failed.id, insert(:user).id)

    %{host: host, payment: saved} = failed_payment("card_saved")
    assert {:error, :invalid_payment_state} = RecoverySessions.create(saved.id, host.id)
  end

  test "recovery completion stores intent and charge while preserving completed meeting" do
    %{meeting: meeting, payment: payment} = failed_payment("action_required")

    payment =
      Ecto.Changeset.change(payment, stripe_recovery_session_id: "cs_RECOVER")
      |> Tymeslot.Repo.update!()

    expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_RECOVER", opts ->
      assert opts[:connect_account] == "acct_HOST"
      {:ok, %{"id" => "pi_RECOVER", "latest_charge" => "ch_RECOVER"}}
    end)

    event = recovery_event("evt_RECOVER", "cs_RECOVER", payment, "pi_RECOVER", nil)
    assert :ok = CheckoutSessionCompleted.handle(event)

    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "paid"
    assert reloaded.stripe_payment_intent_id == "pi_RECOVER"
    assert reloaded.stripe_charge_id == "ch_RECOVER"
    assert {:ok, %{status: "completed"}} = MeetingQueries.get_meeting(meeting.id)

    assert :ok = CheckoutSessionCompleted.handle(Map.put(event, "id", "evt_DUPLICATE"))
    assert BookingPaymentQueries.get(payment.id).status == "paid"
  end

  test "recovery expiry preserves failure and late completion for another session has no effect" do
    %{meeting: meeting, payment: payment} = failed_payment("charge_failed")

    payment =
      Ecto.Changeset.change(payment, stripe_recovery_session_id: "cs_EXPIRE")
      |> Tymeslot.Repo.update!()

    assert :ok =
             CheckoutSessionExpired.handle(
               recovery_event("evt_EXPIRE", "cs_EXPIRE", payment, nil, nil)
             )

    assert BookingPaymentQueries.get(payment.id).status == "charge_failed"
    assert {:ok, %{status: "completed"}} = MeetingQueries.get_meeting(meeting.id)

    late = recovery_event("evt_OLD", "cs_OLD", payment, "pi_OLD", "ch_OLD")
    assert :ok = CheckoutSessionCompleted.handle(late)
    assert BookingPaymentQueries.get(payment.id).status == "charge_failed"
  end

  test "recovery completion remains failed when Stripe cannot provide a Charge ID" do
    %{payment: payment} = failed_payment("charge_failed")

    payment =
      Ecto.Changeset.change(payment, stripe_recovery_session_id: "cs_UNCERTAIN")
      |> Tymeslot.Repo.update!()

    expect(StripeAdapterMock, :retrieve_payment_intent, fn "pi_UNCERTAIN", _opts ->
      {:error, :timeout}
    end)

    event = recovery_event("evt_UNCERTAIN", "cs_UNCERTAIN", payment, "pi_UNCERTAIN", nil)
    assert {:error, :recovery_charge_unavailable} = CheckoutSessionCompleted.handle(event)
    assert BookingPaymentQueries.get(payment.id).status == "charge_failed"
  end

  defp failed_payment(status) do
    host = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: host.id,
        status: "completed",
        service_snapshot: @snapshot
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: host.id,
        stripe_account_id: "acct_HOST",
        payment_timing: "deferred",
        service_snapshot: @snapshot,
        amount_cents: 19_000,
        currency: "usd",
        status: status,
        charge_attempt: 1
      )

    %{host: host, meeting: meeting, payment: payment}
  end

  defp recovery_event(event_id, session_id, payment, intent_id, charge_id) do
    %{
      "id" => event_id,
      "account" => "acct_HOST",
      "data" => %{
        "object" => %{
          "id" => session_id,
          "mode" => "payment",
          "client_reference_id" => payment.meeting_id,
          "payment_intent" => intent_id,
          "metadata" => %{
            "booking_payment_id" => payment.id,
            "meeting_id" => payment.meeting_id,
            "service_id" => "in-home-consultation",
            "charge_attempt" => "1",
            "payment_purpose" => "recovery"
          },
          "payment_intent_data" => %{"latest_charge" => charge_id},
          "latest_charge" => charge_id
        }
      }
    }
  end
end
