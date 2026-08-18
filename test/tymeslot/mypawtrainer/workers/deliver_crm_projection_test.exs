defmodule Tymeslot.MyPawTrainer.Workers.DeliverCrmProjectionTest do
  use Tymeslot.DataCase, async: false

  import Ecto.Query

  alias Tymeslot.MyPawTrainer.CrmProjection
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.MyPawTrainer.Workers.DeliverCrmProjection

  defmodule FakeClient do
    def post(url, body, headers, options) do
      send(
        Application.fetch_env!(:tymeslot, :crm_projection_test_pid),
        {:crm_request, url, body, headers, options}
      )

      case Application.fetch_env!(:tymeslot, :crm_projection_test_response) do
        {:raise, reason} -> raise reason
        response -> response
      end
    end

    def reconcile(url, body, headers, options) do
      send(
        Application.fetch_env!(:tymeslot, :crm_projection_test_pid),
        {:crm_reconcile, url, body, headers, options}
      )

      Application.fetch_env!(:tymeslot, :crm_projection_test_reconcile_response)
    end
  end

  @url "https://crm.mypawtrainer.com/api/v1/tymeslot/booking-projection"
  @secret "test-crm-projection-secret-separate-from-price"

  setup do
    keys =
      ~w(crm_projection_delivery_enabled crm_projection_url crm_projection_secret crm_projection_http_client crm_projection_test_pid crm_projection_test_response crm_projection_test_reconcile_response crm_projection_now crm_projection_nonce crm_projection_jitter environment)a

    previous = Map.new(keys, &{&1, Application.get_env(:tymeslot, &1)})

    Application.put_env(:tymeslot, :crm_projection_delivery_enabled, true)
    Application.put_env(:tymeslot, :crm_projection_url, @url)
    Application.put_env(:tymeslot, :crm_projection_secret, @secret)
    Application.put_env(:tymeslot, :crm_projection_http_client, FakeClient)
    Application.put_env(:tymeslot, :crm_projection_test_pid, self())

    Application.put_env(
      :tymeslot,
      :crm_projection_test_response,
      response(200, ~s({"status":"applied"}))
    )

    Application.put_env(
      :tymeslot,
      :crm_projection_test_reconcile_response,
      response(200, ~s({"status":"missing"}))
    )

    Application.put_env(:tymeslot, :crm_projection_now, ~U[2026-08-17 20:00:00Z])
    Application.put_env(:tymeslot, :crm_projection_nonce, "crm-nonce-1234567890")
    Application.put_env(:tymeslot, :crm_projection_jitter, 0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:tymeslot, key)
        {key, value} -> Application.put_env(:tymeslot, key, value)
      end)
    end)
  end

  test "signs the exact booking projection with the separate CRM credential" do
    event = insert_event()
    assert :ok = perform()

    assert_receive {:crm_request, @url, body, headers, options}
    decoded = Jason.decode!(body)
    assert decoded["type"] == "booking.confirmed.v1"
    assert decoded["eventId"] == event.event_id
    assert decoded["aggregateVersion"] == 1
    assert decoded["projection"] == event.payload
    assert header(headers, "idempotency-key") == event.event_id

    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    input = "2026-08-17T20:00:00Z\ncrm-nonce-1234567890\n#{event.event_id}\n#{digest}"
    expected = :crypto.mac(:hmac, :sha256, @secret, input) |> Base.encode16(case: :lower)
    assert header(headers, "x-mpt-signature") == expected
    assert options[:timeout] == 5_000
    assert options[:max_response_bytes] == 16 * 1024
    assert Repo.reload(event).state == "delivered"
  end

  test "is disabled by default and never claims price events" do
    event = insert_event()
    Application.put_env(:tymeslot, :crm_projection_delivery_enabled, false)
    assert :ok = perform()
    assert Repo.reload(event).state == "pending"

    Repo.update_all(
      from(row in ProjectionOutboxSchema, where: row.id == ^event.id),
      set: [event_type: "service.price_published.v1"]
    )

    price = Repo.reload(event)
    Application.put_env(:tymeslot, :crm_projection_delivery_enabled, true)
    assert :ok = perform()
    assert Repo.reload(price).attempt_count == 0
  end

  test "acknowledges duplicate and older versions without regression" do
    for {version, result} <- [
          {2, response(200, ~s({"status":"duplicate"}))},
          {3, response(409, ~s({"error":"older_aggregate_version"}))}
        ] do
      event = insert_event(version)
      Application.put_env(:tymeslot, :crm_projection_test_response, result)
      assert :ok = perform()
      assert Repo.reload(event).state == "delivered"
    end
  end

  test "retries transient outcomes, honors Retry-After, and dead-letters authorization" do
    for {version, result, code, delay} <- [
          {10, {:error, %Req.TransportError{reason: :timeout}}, "timeout", 2},
          {11, response(408, "{}"), "http_408", 2},
          {12, response(429, "{}", [{"retry-after", "120"}]), "http_429", 120},
          {13, response(503, "private body"), "http_5xx", 2},
          {14, response(200, ~s({"status":"unexpected"})), "invalid_response", 2}
        ] do
      event = insert_event(version)
      Application.put_env(:tymeslot, :crm_projection_test_response, result)
      assert :ok = perform()
      assert %{state: "pending", error_code: ^code} = Repo.reload(event)

      assert Repo.reload(event).next_attempt_at ==
               DateTime.add(~U[2026-08-17 20:00:00Z], delay, :second)
    end

    auth = insert_event(20)
    Application.put_env(:tymeslot, :crm_projection_test_response, response(403, "{}"))
    assert :ok = perform()
    assert %{state: "dead_letter", error_code: "authentication_failed"} = Repo.reload(auth)
  end

  test "reconciles uncertain create by immutable booking ID and version" do
    event = insert_event()

    Application.put_env(
      :tymeslot,
      :crm_projection_test_response,
      response(409, ~s({"error":"uncertain_create"}))
    )

    Application.put_env(
      :tymeslot,
      :crm_projection_test_reconcile_response,
      response(200, ~s({"status":"current"}))
    )

    assert :ok = perform()
    assert_receive {:crm_reconcile, _, body, _, _}
    assert Jason.decode!(body) == %{"bookingId" => event.aggregate_id, "aggregateVersion" => 1}
    assert Repo.reload(event).state == "delivered"
  end

  test "a crash leaves delivery reclaimable without changing the booking" do
    event = insert_event()
    meeting = Repo.get!(Tymeslot.Meetings.MeetingSchema, event.aggregate_id)
    Application.put_env(:tymeslot, :crm_projection_test_response, {:raise, "crash"})
    assert_raise RuntimeError, "crash", &perform/0
    assert Repo.reload(event).state == "delivering"
    assert Repo.reload(meeting).status == "confirmed"

    Repo.update_all(from(row in ProjectionOutboxSchema, where: row.id == ^event.id),
      set: [updated_at: ~U[2026-08-17 19:00:00Z]]
    )

    Application.put_env(
      :tymeslot,
      :crm_projection_test_response,
      response(200, ~s({"status":"duplicate"}))
    )

    assert :ok = perform()
    assert Repo.reload(event).state == "delivered"
  end

  test "never transmits a corrupted payload with an unknown key" do
    event = insert_event()

    Repo.update_all(
      from(row in ProjectionOutboxSchema, where: row.id == ^event.id),
      set: [payload: Map.put(event.payload, "phone", "private")]
    )

    assert :ok = perform()
    refute_receive {:crm_request, _, _, _, _}
    assert %{state: "dead_letter", error_code: "invalid_payload"} = Repo.reload(event)
  end

  defp insert_event(version \\ 1) do
    meeting =
      insert(:meeting,
        service_snapshot: %{
          "service_id" => "online-consultation",
          "service_name" => "Online behavior consultation",
          "delivery_mode" => "virtual"
        }
      )

    {:ok, {:ok, event}} =
      Repo.transaction(fn ->
        CrmProjection.append(meeting, "confirmed",
          aggregate_version: version,
          now: ~U[2026-08-17 19:00:00Z]
        )
      end)

    event
  end

  defp perform, do: DeliverCrmProjection.perform(%Oban.Job{args: %{}})

  defp response(status, body, headers \\ []),
    do: {:ok, %{status: status, body: body, headers: headers}}

  defp header(headers, name), do: headers |> Enum.into(%{}) |> Map.fetch!(name)
end
