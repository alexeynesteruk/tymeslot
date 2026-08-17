defmodule Tymeslot.MeetingPayments.Workers.ReconcileDeferredPaymentsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Ecto.Query
  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.ReconcileDeferredPayments
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

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
  setup :set_mox_from_context

  describe "perform/1" do
    test "reconciles a completed setup session to card_saved without charging" do
      {meeting, payment} = insert_stale_setup(session_id: "cs_SETUP_DONE")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_SETUP_DONE", opts ->
        assert opts[:connect_account] == "acct_HOST"

        {:ok,
         %{
           "id" => "cs_SETUP_DONE",
           "mode" => "setup",
           "status" => "complete",
           "setup_intent" => "seti_DONE",
           "client_reference_id" => meeting.id
         }}
      end)

      assert {:ok, %{reconciled: 1, skipped: 0, errors: 0}} =
               perform_job(ReconcileDeferredPayments, %{})

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == "card_saved"
      assert reloaded.stripe_setup_intent_id == "seti_DONE"
      assert is_nil(reloaded.stripe_charge_id)

      {:ok, confirmed} = MeetingQueries.get_meeting(meeting.id)
      assert confirmed.status == "confirmed"
    end

    test "reconciles an expired setup session to cancelled and releases the slot" do
      {meeting, payment} = insert_stale_setup(session_id: "cs_SETUP_EXPIRED")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_SETUP_EXPIRED", opts ->
        assert opts[:connect_account] == "acct_HOST"

        {:ok,
         %{
           "id" => "cs_SETUP_EXPIRED",
           "mode" => "setup",
           "status" => "expired",
           "client_reference_id" => meeting.id
         }}
      end)

      assert {:ok, %{reconciled: 1}} = perform_job(ReconcileDeferredPayments, %{})

      assert BookingPaymentQueries.get(payment.id).status == "cancelled"
      {:ok, expired} = MeetingQueries.get_meeting(meeting.id)
      assert expired.status == "expired"
    end

    test "ignores fresh setup_pending rows and never creates a charge" do
      insert_stale_setup(session_id: "cs_FRESH", inserted_at: DateTime.utc_now(:second))

      assert {:ok, %{reconciled: 0, skipped: 0, errors: 0}} =
               perform_job(ReconcileDeferredPayments, %{})
    end
  end

  defp insert_stale_setup(opts) do
    inserted_at =
      Keyword.get_lazy(opts, :inserted_at, fn ->
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      end)

    user = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "awaiting_card",
        service_snapshot: @snapshot
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        stripe_account_id: "acct_HOST",
        status: "setup_pending",
        payment_timing: "deferred",
        service_snapshot: @snapshot,
        amount_cents: 4_900,
        currency: "usd",
        stripe_checkout_session_id: Keyword.get(opts, :session_id, "cs_STALE_SETUP")
      )

    {1, _result} =
      Repo.update_all(
        from(b in BookingPaymentSchema, where: b.id == ^payment.id),
        set: [inserted_at: inserted_at]
      )

    {meeting, Repo.reload!(payment)}
  end
end
