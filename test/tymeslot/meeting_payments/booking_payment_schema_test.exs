defmodule Tymeslot.MeetingPayments.BookingPaymentSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema

  @valid_attrs %{
    stripe_account_id: "acct_TEST",
    host_user_id: 1,
    host_email: "host@example.com",
    attendee_email: "attendee@example.com",
    meeting_type_name: "Consult",
    amount_cents: 5000,
    currency: "eur",
    application_fee_cents: 25
  }

  describe "create_changeset/1" do
    test "is valid with required attrs" do
      cs = BookingPaymentSchema.create_changeset(@valid_attrs)
      assert cs.valid?
    end

    test "rejects amount_cents == 0" do
      cs = BookingPaymentSchema.create_changeset(%{@valid_attrs | amount_cents: 0})
      refute cs.valid?
      assert "must be greater than 0" in errors_on(cs).amount_cents
    end

    test "rejects negative refunded" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :refunded_amount_cents, -1))

      refute cs.valid?
      assert "must be non-negative" in errors_on(cs).refunded_amount_cents
    end

    test "rejects refunded greater than amount" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :refunded_amount_cents, 6000))

      refute cs.valid?
      assert "cannot exceed amount_cents" in errors_on(cs).refunded_amount_cents
    end

    test "rejects unknown status" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :status, "weird"))

      refute cs.valid?
      assert "is invalid" in errors_on(cs).status
    end

    test "rejects missing host_email" do
      cs =
        BookingPaymentSchema.create_changeset(Map.delete(@valid_attrs, :host_email))

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).host_email
    end

    test "rejects negative application_fee_cents" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :application_fee_cents, -1))

      refute cs.valid?
      assert "must be greater than or equal to 0" in errors_on(cs).application_fee_cents
    end
  end

  describe "update_changeset/2" do
    test "transitions status from pending to paid" do
      {:ok, payment} =
        @valid_attrs
        |> BookingPaymentSchema.create_changeset()
        |> Repo.insert()

      cs = BookingPaymentSchema.update_changeset(payment, %{status: "paid"})
      assert cs.valid?

      {:ok, updated} = Repo.update(cs)
      assert updated.status == "paid"
    end

    test "DB CHECK rejects refunded > amount" do
      {:ok, payment} =
        @valid_attrs
        |> BookingPaymentSchema.create_changeset()
        |> Repo.insert()

      assert_raise Postgrex.Error, ~r/refunded_amount_within_bounds/, fn ->
        Repo.query!(
          "UPDATE booking_payments SET refunded_amount_cents = $1 WHERE id = $2",
          [99_999, UUID.dump!(payment.id)]
        )
      end
    end
  end

  describe "deferred setup states and immutable snapshot" do
    @snapshot %{
      "service_id" => "online-consultation",
      "service_name" => "Online behavior consultation",
      "amount_cents" => 14_000,
      "currency" => "usd",
      "duration_minutes" => 90,
      "delivery_mode" => "virtual",
      "event_type_version" => 1
    }

    @deferred_statuses ~w(
      setup_pending card_saved charge_processing charge_failed
      action_required paid partially_refunded refunded disputed cancelled
    )

    test "accepts the deferred payment lifecycle statuses" do
      Enum.each(@deferred_statuses, fn status ->
        cs =
          BookingPaymentSchema.create_changeset(
            Map.merge(@valid_attrs, %{
              status: status,
              payment_timing: "deferred",
              service_snapshot: @snapshot,
              amount_cents: 14_000,
              currency: "usd"
            })
          )

        assert cs.valid?, "expected #{status} to be valid, got #{inspect(errors_on(cs))}"
      end)
    end

    test "deferred payments require a service snapshot, Stripe account, amount, and currency" do
      cs =
        BookingPaymentSchema.create_changeset(
          Map.merge(@valid_attrs, %{
            payment_timing: "deferred",
            status: "setup_pending",
            service_snapshot: @snapshot
          })
        )

      assert cs.valid?

      refute BookingPaymentSchema.create_changeset(
               Map.merge(@valid_attrs, %{
                 payment_timing: "deferred",
                 status: "setup_pending",
                 service_snapshot: %{}
               })
             ).valid?

      refute BookingPaymentSchema.create_changeset(
               Map.merge(Map.delete(@valid_attrs, :stripe_account_id), %{
                 payment_timing: "deferred",
                 status: "setup_pending",
                 service_snapshot: @snapshot
               })
             ).valid?
    end

    test "copies the meeting snapshot and rejects later mutation" do
      {:ok, payment} =
        Map.merge(@valid_attrs, %{
          payment_timing: "deferred",
          status: "setup_pending",
          service_snapshot: @snapshot,
          amount_cents: 14_000,
          currency: "usd"
        })
        |> BookingPaymentSchema.create_changeset()
        |> Repo.insert()

      assert payment.payment_timing == "deferred"
      assert payment.service_snapshot["service_id"] == "online-consultation"
      assert payment.service_snapshot["amount_cents"] == 14_000
      assert payment.service_snapshot["event_type_version"] == 1

      updated =
        BookingPaymentSchema.update_changeset(payment, %{
          service_snapshot: Map.put(@snapshot, "amount_cents", 19_000)
        })

      refute updated.valid?
      assert "cannot be changed after it is set" in errors_on(updated).service_snapshot
    end

    test "retains the original snapshot after the event type price changes" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Online behavior consultation",
          duration_minutes: 90,
          service_id: "online-consultation",
          service_price_cents: 14_000,
          service_currency: "usd",
          event_type_version: 1,
          is_active: true
        )

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          duration: 90,
          status: "awaiting_card",
          service_snapshot: @snapshot
        )

      {:ok, payment} =
        Map.merge(@valid_attrs, %{
          host_user_id: user.id,
          meeting_id: meeting.id,
          payment_timing: "deferred",
          status: "setup_pending",
          service_snapshot: meeting.service_snapshot,
          amount_cents: meeting.service_snapshot["amount_cents"],
          currency: meeting.service_snapshot["currency"]
        })
        |> BookingPaymentSchema.create_changeset()
        |> Repo.insert()

      {:ok, _updated_type} =
        meeting_type
        |> Ecto.Changeset.change(%{service_price_cents: 15_000, event_type_version: 2})
        |> Repo.update()

      reloaded = Repo.get!(BookingPaymentSchema, payment.id)
      assert reloaded.service_snapshot["amount_cents"] == 14_000
      assert reloaded.service_snapshot["event_type_version"] == 1
      assert reloaded.service_snapshot["service_id"] == "online-consultation"
      assert reloaded.service_snapshot["duration_minutes"] == 90
      assert reloaded.service_snapshot["currency"] == "usd"
      assert reloaded.service_snapshot["delivery_mode"] == "virtual"
    end
  end
end
