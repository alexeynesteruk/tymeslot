defmodule Tymeslot.MeetingPayments.BookingPaymentAuditSchema do
  @moduledoc """
  Append-only explanation of a booking-payment state change.

  `meeting_id` is stored without a foreign key so retention can delete the
  meeting without deleting the audit trail.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          booking_payment_id: Ecto.UUID.t() | nil,
          meeting_id: Ecto.UUID.t() | nil,
          actor_type: String.t() | nil,
          actor_user_id: integer() | nil,
          action: String.t() | nil,
          attempt: integer(),
          amount_cents: integer() | nil,
          result: String.t() | nil,
          stripe_object_id: String.t() | nil,
          detail_code: String.t() | nil,
          occurred_at: DateTime.t() | nil
        }

  schema "booking_payment_audits" do
    field :booking_payment_id, :binary_id
    field :meeting_id, :binary_id
    field :actor_type, :string
    field :actor_user_id, :integer
    field :action, :string
    field :attempt, :integer, default: 0
    field :amount_cents, :integer
    field :result, :string
    field :stripe_object_id, :string
    field :detail_code, :string
    field :occurred_at, :utc_datetime
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :booking_payment_id,
      :meeting_id,
      :actor_type,
      :actor_user_id,
      :action,
      :attempt,
      :amount_cents,
      :result,
      :stripe_object_id,
      :detail_code,
      :occurred_at
    ])
    |> validate_required([:booking_payment_id, :actor_type, :action, :result, :occurred_at])
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
  end
end
