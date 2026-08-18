defmodule Tymeslot.MeetingPayments.CardSetupsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.CardSetups
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Profiles

  @snapshot %{
    "service_id" => "discovery-call",
    "service_name" => "Discovery call",
    "amount_cents" => 4_900,
    "currency" => "usd",
    "duration_minutes" => 30,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  setup :verify_on_exit!

  setup do
    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    previous_payments = Application.get_env(:tymeslot, :meeting_payments_enabled)
    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    on_exit(fn ->
      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_payments)
      Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
    end)

    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{booking_theme: "1"})

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_HOST",
      default_currency: "usd",
      charges_enabled: true
    )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Discovery call",
        duration_minutes: 30,
        payment_required: true,
        payment_timing: "deferred",
        price_cents: 4_900,
        service_id: "discovery-call",
        service_price_cents: 4_900,
        service_currency: "usd",
        event_type_version: 1,
        is_active: true
      )

    %{user: user, meeting_type: meeting_type}
  end

  describe "create_session_for_booking/1" do
    test "creates a Connect customer and binds it on the setup session",
         %{user: user, meeting_type: meeting_type} do
      meeting = insert_deferred_meeting(user, meeting_type)

      expect(StripeAdapterMock, :create_customer, fn params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert opts[:idempotency_key] =~ ~r/^setup-customer:[0-9a-f-]{36}$/
        assert params.email == "guest@example.com"
        assert params.name == "Guest"
        {:ok, %{"id" => "cus_SETUP"}}
      end)

      expect(StripeAdapterMock, :create_setup_checkout_session, fn params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert params.customer == "cus_SETUP"
        refute Map.has_key?(params, :customer_email)

        {:ok,
         %{
           id: "cs_SETUP",
           url: "https://checkout.stripe.com/cs_SETUP",
           setup_intent: %{id: "seti_SETUP"}
         }}
      end)

      assert {:ok, %{booking_payment: payment}} = CardSetups.create_session_for_booking(meeting)
      assert payment.stripe_customer_id == "cus_SETUP"
    end

    test "creates a setup-mode session without charging and snapshots the meeting price",
         %{user: user, meeting_type: meeting_type} do
      meeting = insert_deferred_meeting(user, meeting_type)

      test_pid = self()

      expect(StripeAdapterMock, :create_customer, fn params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert params.email == "guest@example.com"
        {:ok, %{"id" => "cus_SETUP"}}
      end)

      expect(StripeAdapterMock, :create_setup_checkout_session, fn params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert opts[:idempotency_key] =~ ~r/^setup-checkout:[0-9a-f-]{36}$/
        send(test_pid, {:setup_opts, opts})
        assert params.mode == "setup"
        assert params.payment_method_types == ["card"]
        assert params.customer == "cus_SETUP"
        refute Map.has_key?(params, :customer_email)
        payment = BookingPaymentQueries.by_meeting_id(meeting.id)
        assert params.setup_intent_data.metadata.meeting_id == meeting.id
        assert params.setup_intent_data.metadata.booking_payment_id == payment.id
        assert params.setup_intent_data.metadata.service_id == "discovery-call"
        assert params.setup_intent_data.metadata.service_version == 1
        refute Map.has_key?(params, :payment_intent_data)
        refute Map.has_key?(params, :line_items)
        refute Map.has_key?(params, :amount)
        refute Map.has_key?(params, :capture_method)

        {:ok,
         %{
           id: "cs_SETUP",
           url: "https://checkout.stripe.com/cs_SETUP",
           setup_intent: %{id: "seti_SETUP"}
         }}
      end)

      assert {:ok, %{checkout_url: url, booking_payment: payment}} =
               CardSetups.create_session_for_booking(meeting)

      assert url =~ "checkout.stripe.com/cs_SETUP"
      assert payment.status == "setup_pending"
      assert payment.payment_timing == "deferred"
      assert payment.amount_cents == 4_900
      assert payment.currency == "usd"
      assert payment.service_snapshot["service_id"] == "discovery-call"
      assert payment.service_snapshot["event_type_version"] == 1
      assert payment.stripe_checkout_session_id == "cs_SETUP"
      assert payment.stripe_setup_intent_id == "seti_SETUP"
      assert is_nil(payment.stripe_payment_intent_id)
      assert is_nil(payment.stripe_charge_id)

      assert_received {:setup_opts, opts}
      assert opts[:idempotency_key] == "setup-checkout:#{payment.id}"
    end

    test "persists setup_pending before Stripe is called and keeps the row if Stripe fails",
         %{user: user, meeting_type: meeting_type} do
      meeting = insert_deferred_meeting(user, meeting_type)
      test_pid = self()

      expect(StripeAdapterMock, :create_customer, fn _params, _opts ->
        {:ok, %{"id" => "cus_FAIL"}}
      end)

      expect(StripeAdapterMock, :create_setup_checkout_session, fn _params, _opts ->
        payment = BookingPaymentQueries.by_meeting_id(meeting.id)
        send(test_pid, {:pre_stripe_payment, payment})
        {:error, :stripe_unreachable}
      end)

      assert {:error, :stripe_unreachable} = CardSetups.create_session_for_booking(meeting)

      assert_received {:pre_stripe_payment, payment}
      assert payment.status == "setup_pending"
      assert is_nil(payment.stripe_checkout_session_id)

      leftover = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert leftover.status == "setup_pending"
      assert leftover.stripe_customer_id == "cus_FAIL"
      assert is_nil(leftover.stripe_checkout_session_id)
    end

    test "retrieves an expanded SetupIntent when Stripe returns a bare id",
         %{user: user, meeting_type: meeting_type} do
      meeting = insert_deferred_meeting(user, meeting_type)

      expect(StripeAdapterMock, :create_customer, fn _params, _opts ->
        {:ok, %{"id" => "cus_BARE"}}
      end)

      expect(StripeAdapterMock, :create_setup_checkout_session, fn _params, _opts ->
        {:ok,
         %{
           id: "cs_BARE",
           url: "https://checkout.stripe.com/cs_BARE",
           setup_intent: "seti_BARE"
         }}
      end)

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_BARE", opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert opts[:expand] == ["setup_intent"]

        {:ok,
         %{
           "id" => "cs_BARE",
           "setup_intent" => %{"id" => "seti_BARE"}
         }}
      end)

      assert {:ok, %{booking_payment: payment}} = CardSetups.create_session_for_booking(meeting)
      assert payment.stripe_setup_intent_id == "seti_BARE"
    end

    test "does not open Checkout when customer creation fails",
         %{user: user, meeting_type: meeting_type} do
      meeting = insert_deferred_meeting(user, meeting_type)

      expect(StripeAdapterMock, :create_customer, fn _params, _opts ->
        {:error, :stripe_unreachable}
      end)

      assert {:error, :stripe_unreachable} = CardSetups.create_session_for_booking(meeting)
      leftover = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert leftover.status == "setup_pending"
      assert is_nil(leftover.stripe_customer_id)
    end

    test "does not call the charge checkout path", %{user: user, meeting_type: meeting_type} do
      meeting = insert_deferred_meeting(user, meeting_type)

      expect(StripeAdapterMock, :create_customer, fn _params, _opts ->
        {:ok, %{"id" => "cus_ONLY_SETUP"}}
      end)

      expect(StripeAdapterMock, :create_setup_checkout_session, fn _params, _opts ->
        {:ok,
         %{
           id: "cs_ONLY_SETUP",
           url: "https://checkout.stripe.com/cs_ONLY_SETUP",
           setup_intent: %{id: "seti_ONLY_SETUP"}
         }}
      end)

      assert {:ok, _result} = CardSetups.create_session_for_booking(meeting)
    end
  end

  defp insert_deferred_meeting(user, meeting_type) do
    insert(:meeting,
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id,
      meeting_type_ref: meeting_type,
      attendee_email: "guest@example.com",
      attendee_name: "Guest",
      attendee_locale: "en",
      status: "awaiting_card",
      duration: 30,
      service_snapshot: @snapshot
    )
  end
end
