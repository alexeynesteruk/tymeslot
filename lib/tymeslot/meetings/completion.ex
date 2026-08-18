defmodule Tymeslot.Meetings.Completion do
  @moduledoc "Owner-authorized completion for direct-service meetings."

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingPayments.BookingPaymentAudits
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MyPawTrainer.ServiceCatalog
  alias Tymeslot.MyPawTrainer.FollowUps
  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.Repo

  @spec complete(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Tymeslot.Meetings.MeetingSchema.t()}
          | {:error, :not_found | :not_authorized | :not_direct_service | :invalid_state}
  def complete(meeting_id, actor_user_id) when is_integer(actor_user_id) do
    Repo.transaction(fn ->
      with {:ok, meeting} <- MeetingQueries.get_meeting_for_update(meeting_id),
           :ok <- authorize(meeting, actor_user_id),
           :ok <- require_direct_service(meeting),
           :ok <- require_confirmed(meeting),
           {:ok, completed} <- MeetingQueries.update_meeting(meeting, %{status: "completed"}),
           :ok <- audit_completion(completed, actor_user_id),
           {:ok, _entitlement} <- FollowUps.create_entitlement(completed),
           :ok <- CrmProjection.append_transition(completed, "completed") do
        completed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def complete(_meeting_id, _actor_user_id), do: {:error, :not_authorized}

  defp authorize(%{organizer_user_id: actor_user_id}, actor_user_id), do: :ok
  defp authorize(_meeting, _actor_user_id), do: {:error, :not_authorized}

  defp require_direct_service(%{service_snapshot: %{"service_id" => service_id}}) do
    if ServiceCatalog.direct_bookable?(service_id), do: :ok, else: {:error, :not_direct_service}
  end

  defp require_direct_service(_meeting), do: {:error, :not_direct_service}

  defp require_confirmed(%{status: "confirmed"}), do: :ok
  defp require_confirmed(_meeting), do: {:error, :invalid_state}

  defp audit_completion(meeting, actor_user_id) do
    case BookingPaymentQueries.by_meeting_id(meeting.id) do
      nil ->
        :ok

      payment ->
        case BookingPaymentAudits.append(%{
               booking_payment_id: payment.id,
               meeting_id: meeting.id,
               actor_type: "owner",
               actor_user_id: actor_user_id,
               action: "meeting_completed",
               attempt: payment.charge_attempt,
               amount_cents: payment.service_snapshot["amount_cents"],
               result: "completed"
             }) do
          {:ok, _audit} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
