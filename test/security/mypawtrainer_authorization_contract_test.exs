defmodule Tymeslot.Security.MyPawTrainerAuthorizationContractTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MeetingPayments.ManualCharges
  alias Tymeslot.MeetingPayments.RecoverySessions
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Meetings.Completion
  alias Tymeslot.MyPawTrainer.FollowUps
  alias Tymeslot.MyPawTrainer.FollowUpEntitlementSchema
  alias Tymeslot.MyPawTrainer.PriceProjection
  alias Tymeslot.MyPawTrainer.ZipAllowlist

  @snapshot %{
    "service_id" => "online-consultation",
    "service_name" => "Online behavior consultation",
    "amount_cents" => 14_000,
    "currency" => "usd",
    "duration_minutes" => 90,
    "delivery_mode" => "virtual",
    "event_type_version" => 1
  }

  test "foreign hosts cannot mutate owner-scoped booking operations" do
    owner = insert(:user)
    foreign = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: owner.id,
        status: "confirmed",
        service_snapshot: @snapshot
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: owner.id,
        payment_timing: "deferred",
        status: "card_saved",
        amount_cents: 14_000,
        currency: "usd",
        service_snapshot: @snapshot
      )

    failed_payment =
      insert(:booking_payment,
        host_user_id: owner.id,
        payment_timing: "deferred",
        status: "charge_failed",
        amount_cents: 14_000,
        currency: "usd",
        service_snapshot: @snapshot
      )

    paid_payment =
      insert(:booking_payment,
        host_user_id: owner.id,
        payment_timing: "deferred",
        status: "paid",
        paid_at: DateTime.utc_now(:second),
        stripe_charge_id: "ch_contract",
        amount_cents: 14_000,
        currency: "usd",
        service_snapshot: @snapshot
      )

    %FollowUpEntitlementSchema{}
    |> FollowUpEntitlementSchema.changeset(%{
      source_meeting_id: meeting.id,
      owner_user_id: owner.id,
      attendee_hash: :crypto.hash(:sha256, meeting.attendee_email),
      status: "available",
      meeting_timezone: "America/New_York",
      not_before: DateTime.utc_now(:second),
      expires_at: DateTime.utc_now(:second) |> DateTime.add(10, :day)
    })
    |> Repo.insert!()

    assert {:error, :not_authorized} = Completion.complete(meeting.id, foreign.id)
    assert {:error, :not_authorized} = ManualCharges.reserve(payment.id, foreign.id)
    assert {:error, :not_authorized} = RecoverySessions.create(failed_payment.id, foreign.id)

    assert {:error, :not_authorized} =
             Refunds.issue_refund(paid_payment.id, foreign.id, 1_000)

    assert {:error, :not_authorized} = FollowUps.issue_link(meeting.id, foreign.id)
  end

  test "foreign hosts cannot write ZIPs or prices" do
    owner = insert(:user)
    foreign = insert(:user)

    event_type =
      insert(:meeting_type,
        user: owner,
        service_id: "online-consultation",
        service_price_cents: 14_000,
        service_currency: "usd",
        event_type_version: 1
      )

    assert {:error, :unauthorized} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: foreign.id)

    assert {:error, :not_found} =
             PriceProjection.publish(event_type.id, foreign.id, 1, 15_000, "usd")

    refute ZipAllowlist.eligible?(owner.id, "32084")
    assert Repo.reload(event_type).service_price_cents == 14_000
  end
end
