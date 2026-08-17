defmodule Tymeslot.MeetingPayments.BookingPaymentAudits do
  @moduledoc """
  Append-only writer for booking-payment audits.
  """

  import Ecto.Query

  alias Tymeslot.MeetingPayments.BookingPaymentAuditSchema
  alias Tymeslot.Repo

  @spec append(map()) :: {:ok, BookingPaymentAuditSchema.t()} | {:error, Ecto.Changeset.t()}
  def append(attrs) do
    attrs
    |> Map.put_new_lazy(:occurred_at, fn -> DateTime.utc_now(:second) end)
    |> BookingPaymentAuditSchema.create_changeset()
    |> Repo.insert()
  end

  @spec list_for_payment(Ecto.UUID.t()) :: [BookingPaymentAuditSchema.t()]
  def list_for_payment(booking_payment_id) do
    query =
      from a in BookingPaymentAuditSchema,
        where: a.booking_payment_id == ^booking_payment_id,
        order_by: [asc: a.occurred_at, asc: a.id]

    Repo.all(query)
  end
end
