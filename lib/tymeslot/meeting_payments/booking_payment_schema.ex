defmodule Tymeslot.MeetingPayments.BookingPaymentSchema do
  @moduledoc """
  Payment record for a paid meeting. Snapshots host/attendee identity and
  meeting-type details so the row survives meeting deletion and host
  anonymisation (retention).

  status values:
    * pending             — Checkout Session created, awaiting webhook
    * paid                — checkout.session.completed received
    * failed              — Checkout Session expired or attendee cancelled
    * partially_refunded  — host issued at least one partial refund
    * refunded            — full amount refunded
    * disputed            — Stripe dispute opened on the charge
    * setup_pending       — deferred setup Checkout created, card not saved
    * card_saved          — SetupIntent succeeded, charge later
    * charge_processing   — owner-authorized charge in flight
    * charge_failed       — later charge declined or failed
    * action_required     — later charge needs customer authentication
    * cancelled           — setup abandoned or booking cancelled before charge
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.MeetingPayments.PaymentTiming
  alias Tymeslot.Meetings.MeetingSchema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(
    pending paid failed refunded partially_refunded disputed
    setup_pending card_saved charge_processing charge_failed
    action_required cancelled
  )

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stripe_account_id: String.t() | nil,
          host_user_id: integer() | nil,
          host_email: String.t() | nil,
          host_name: String.t() | nil,
          attendee_email: String.t() | nil,
          attendee_name: String.t() | nil,
          meeting_type_name: String.t() | nil,
          booking_theme_id: String.t() | nil,
          stripe_checkout_session_id: String.t() | nil,
          stripe_payment_intent_id: String.t() | nil,
          stripe_charge_id: String.t() | nil,
          stripe_customer_id: String.t() | nil,
          stripe_setup_intent_id: String.t() | nil,
          stripe_payment_method_id: String.t() | nil,
          stripe_recovery_session_id: String.t() | nil,
          amount_cents: integer() | nil,
          currency: String.t() | nil,
          application_fee_cents: integer() | nil,
          payment_timing: String.t(),
          service_snapshot: map(),
          charge_attempt: integer(),
          charge_requested_at: DateTime.t() | nil,
          last_error_code: String.t() | nil,
          status: String.t(),
          paid_at: DateTime.t() | nil,
          refunded_amount_cents: integer(),
          last_event_id: String.t() | nil,
          host_deleted_at: DateTime.t() | nil,
          meeting_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_payments" do
    field :stripe_account_id, :string
    field :host_user_id, :integer
    field :host_email, :string
    field :host_name, :string
    field :attendee_email, :string
    field :attendee_name, :string
    field :meeting_type_name, :string
    field :booking_theme_id, :string

    field :stripe_checkout_session_id, :string
    field :stripe_payment_intent_id, :string
    field :stripe_charge_id, :string
    field :stripe_customer_id, :string
    field :stripe_setup_intent_id, :string
    field :stripe_payment_method_id, :string
    field :stripe_recovery_session_id, :string

    field :amount_cents, :integer
    field :currency, :string
    field :application_fee_cents, :integer
    field :payment_timing, :string, default: "upfront"
    field :service_snapshot, :map, default: %{}
    field :charge_attempt, :integer, default: 0
    field :charge_requested_at, :utc_datetime
    field :last_error_code, :string

    field :status, :string, default: "pending"
    field :paid_at, :utc_datetime
    field :refunded_amount_cents, :integer, default: 0

    field :last_event_id, :string
    field :host_deleted_at, :utc_datetime

    belongs_to :meeting, MeetingSchema, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @required_on_create ~w(
    stripe_account_id host_user_id host_email
    meeting_type_name
    amount_cents currency application_fee_cents
  )a

  @castable @required_on_create ++
              ~w(
                meeting_id host_name attendee_email attendee_name booking_theme_id
                stripe_checkout_session_id stripe_payment_intent_id stripe_charge_id
                stripe_customer_id stripe_setup_intent_id stripe_payment_method_id
                stripe_recovery_session_id payment_timing service_snapshot
                charge_attempt charge_requested_at last_error_code
                status paid_at refunded_amount_cents last_event_id host_deleted_at
              )a

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @castable)
    |> validate_required(@required_on_create)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:payment_timing, PaymentTiming.timings())
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:application_fee_cents, greater_than_or_equal_to: 0)
    |> validate_number(:charge_attempt, greater_than_or_equal_to: 0)
    |> validate_deferred_requirements()
    |> validate_refunded_bounds()
    |> unique_constraint(:meeting_id)
    |> unique_constraint(:stripe_checkout_session_id)
    |> unique_constraint(:stripe_payment_intent_id)
    |> unique_constraint(:stripe_charge_id)
    |> unique_constraint(:stripe_setup_intent_id)
    |> unique_constraint(:stripe_recovery_session_id)
    |> check_constraint(:refunded_amount_cents, name: :refunded_amount_within_bounds)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(schema, attrs) do
    schema
    |> cast(attrs, @castable -- @required_on_create)
    |> reject_service_snapshot_update(schema)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:payment_timing, PaymentTiming.timings())
    |> validate_number(:charge_attempt, greater_than_or_equal_to: 0)
    |> validate_deferred_requirements()
    |> validate_refunded_bounds()
    |> check_constraint(:refunded_amount_cents, name: :refunded_amount_within_bounds)
  end

  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  defp validate_deferred_requirements(changeset) do
    if get_field(changeset, :payment_timing) == "deferred" do
      changeset
      |> validate_required([:service_snapshot, :stripe_account_id, :amount_cents, :currency])
      |> validate_snapshot_present()
    else
      changeset
    end
  end

  defp validate_snapshot_present(changeset) do
    case get_field(changeset, :service_snapshot) do
      snapshot when is_map(snapshot) and map_size(snapshot) > 0 ->
        changeset

      _snapshot ->
        add_error(changeset, :service_snapshot, "can't be blank")
    end
  end

  defp reject_service_snapshot_update(changeset, %__MODULE__{service_snapshot: snapshot})
       when is_map(snapshot) and map_size(snapshot) > 0 do
    if Map.has_key?(changeset.changes, :service_snapshot) do
      add_error(changeset, :service_snapshot, "cannot be changed after it is set")
    else
      changeset
    end
  end

  defp reject_service_snapshot_update(changeset, _schema), do: changeset

  defp validate_refunded_bounds(changeset) do
    refunded = get_field(changeset, :refunded_amount_cents) || 0
    amount = get_field(changeset, :amount_cents) || 0

    cond do
      refunded < 0 ->
        add_error(changeset, :refunded_amount_cents, "must be non-negative")

      refunded > amount ->
        add_error(changeset, :refunded_amount_cents, "cannot exceed amount_cents")

      true ->
        changeset
    end
  end
end
