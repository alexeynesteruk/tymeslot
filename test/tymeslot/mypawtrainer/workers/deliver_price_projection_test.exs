defmodule Tymeslot.MyPawTrainer.Workers.DeliverPriceProjectionTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.MyPawTrainer.PriceProjection
  alias Tymeslot.MyPawTrainer.ProjectionOutbox
  alias Tymeslot.MyPawTrainer.ProjectionOutboxSchema
  alias Tymeslot.MyPawTrainer.Workers.DeliverPriceProjection

  defmodule FakeClient do
    def post(url, body, headers, options) do
      send(Application.fetch_env!(:tymeslot, :price_projection_test_pid), {
        :price_projection_request,
        url,
        body,
        headers,
        options
      })

      case Application.fetch_env!(:tymeslot, :price_projection_test_response) do
        {:raise, reason} -> raise reason
        response -> response
      end
    end
  end

  @url "https://cms.mypawtrainer.com/api/internal/tymeslot/service-price/v1"
  @secret "test-price-projection-secret-with-sufficient-entropy"

  setup do
    keys = [
      :price_projection_delivery_enabled,
      :price_projection_url,
      :price_projection_secret,
      :price_projection_http_client,
      :price_projection_test_pid,
      :price_projection_test_response,
      :price_projection_now,
      :price_projection_nonce,
      :price_projection_jitter,
      :environment
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:tymeslot, &1)})

    Application.put_env(:tymeslot, :price_projection_delivery_enabled, true)
    Application.put_env(:tymeslot, :price_projection_url, @url)
    Application.put_env(:tymeslot, :price_projection_secret, @secret)
    Application.put_env(:tymeslot, :price_projection_http_client, FakeClient)
    Application.put_env(:tymeslot, :price_projection_test_pid, self())

    Application.put_env(
      :tymeslot,
      :price_projection_test_response,
      response(200, ~s({"status":"applied"}))
    )

    Application.put_env(:tymeslot, :price_projection_now, ~U[2026-08-17 20:00:00Z])
    Application.put_env(:tymeslot, :price_projection_nonce, "nonce-1234567890abcdef")
    Application.put_env(:tymeslot, :price_projection_jitter, 0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:tymeslot, key)
        {key, value} -> Application.put_env(:tymeslot, key, value)
      end)
    end)

    :ok
  end

  test "sends the exact signed price contract and marks an applied event delivered" do
    event = insert_event()

    assert :ok = perform()

    assert_receive {:price_projection_request, @url, body, headers, options}
    decoded = Jason.decode!(body)

    assert MapSet.new(Map.keys(decoded)) ==
             MapSet.new(
               ~w(type schemaVersion eventId serviceId cents currency eventTypeVersion aggregateVersion occurredAt routeCompatible)
             )

    assert decoded == %{
             "type" => "service.price_published.v1",
             "schemaVersion" => 1,
             "eventId" => event.event_id,
             "serviceId" => "online-consultation",
             "cents" => 14_500,
             "currency" => "usd",
             "eventTypeVersion" => 2,
             "aggregateVersion" => 2,
             "occurredAt" => "2026-08-17T19:00:00Z",
             "routeCompatible" => true
           }

    assert header(headers, "content-type") == "application/json"
    assert header(headers, "idempotency-key") == event.event_id
    assert header(headers, "x-mpt-event-id") == event.event_id
    assert header(headers, "x-mpt-timestamp") == "2026-08-17T20:00:00Z"
    assert header(headers, "x-mpt-nonce") == "nonce-1234567890abcdef"

    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    signing_input = "2026-08-17T20:00:00Z\nnonce-1234567890abcdef\n#{event.event_id}\n#{digest}"

    assert header(headers, "x-mpt-signature") ==
             :crypto.mac(:hmac, :sha256, @secret, signing_input)
             |> Base.encode16(case: :lower)

    assert options[:timeout] == 5_000
    assert options[:max_response_bytes] == 16 * 1024
    assert Repo.reload(event).state == "delivered"
  end

  test "does not send when disabled or when URL or secret is missing" do
    event = insert_event()

    for {key, value} <- [
          {:price_projection_delivery_enabled, false},
          {:price_projection_url, nil},
          {:price_projection_secret, nil}
        ] do
      Application.put_env(:tymeslot, key, value)
      assert :ok = perform()
      refute_receive {:price_projection_request, _, _, _, _}
      assert Repo.reload(event).state == "pending"

      Application.put_env(
        :tymeslot,
        key,
        if(key == :price_projection_delivery_enabled, do: true, else: config_value(key))
      )
    end
  end

  test "rejects non-TLS delivery outside test mode before sending" do
    event = insert_event()
    Application.put_env(:tymeslot, :price_projection_url, "http://cms.example.test/internal")
    Application.put_env(:tymeslot, :environment, :prod)

    assert :ok = perform()
    refute_receive {:price_projection_request, _, _, _, _}
    assert Repo.reload(event).state == "dead_letter"
    assert Repo.reload(event).error_code == "invalid_url"
  end

  test "rejects an EspoCRM destination before using the price credential" do
    event = insert_event()

    Application.put_env(
      :tymeslot,
      :price_projection_url,
      "https://crm.mypawtrainer.com/api/v1/price-projection"
    )

    assert :ok = perform()
    refute_receive {:price_projection_request, _, _, _, _}
    assert %{state: "dead_letter", error_code: "invalid_url"} = Repo.reload(event)
  end

  test "acknowledges duplicate and stale projection reconciliation responses" do
    for {status, body} <- [
          {200, ~s({"status":"duplicate"})},
          {409, ~s({"error":"stale_projection"})}
        ] do
      event = insert_event(aggregate_version: status)
      Application.put_env(:tymeslot, :price_projection_test_response, response(status, body))

      assert :ok = perform()
      assert Repo.reload(event).state == "delivered"
    end
  end

  test "retries timeout, 408, 429 Retry-After, 5xx, and malformed responses with sanitized codes" do
    cases = [
      {{:error, %Req.TransportError{reason: :timeout}}, "timeout", 2},
      {response(408, ~s({"error":"timeout"})), "http_408", 2},
      {response(429, ~s({"error":"rate_limited"}), [{"retry-after", "120"}]), "http_429", 120},
      {response(503, ~s({"error":"unavailable"})), "http_5xx", 2},
      {response(200, ~s({"status":"surprise","raw":"client@example.com"})), "invalid_response", 2}
    ]

    cases
    |> Enum.with_index(20)
    |> Enum.each(fn {{result, code, delay}, version} ->
      event = insert_event(aggregate_version: version)
      Application.put_env(:tymeslot, :price_projection_test_response, result)

      assert :ok = perform()
      retried = Repo.reload(event)
      assert retried.state == "pending"
      assert retried.error_code == code
      assert retried.next_attempt_at == DateTime.add(~U[2026-08-17 20:00:00Z], delay, :second)
      refute retried.error_code =~ "@"
    end)
  end

  test "bounds exponential backoff and Retry-After" do
    event = insert_event(attempt_count: 6)
    Application.put_env(:tymeslot, :price_projection_test_response, response(503, "{}"))

    assert :ok = perform()
    assert Repo.reload(event).next_attempt_at == ~U[2026-08-17 20:02:08Z]

    later = insert_event(aggregate_version: 31)

    Application.put_env(
      :tymeslot,
      :price_projection_test_response,
      response(429, "{}", [{"retry-after", "999999"}])
    )

    assert :ok = perform()
    assert Repo.reload(later).next_attempt_at == ~U[2026-08-17 21:00:00Z]
  end

  test "dead-letters authentication failures and exhausted retries" do
    auth = insert_event()

    Application.put_env(
      :tymeslot,
      :price_projection_test_response,
      response(401, ~s({"error":"unauthorized"}))
    )

    assert :ok = perform()
    assert %{state: "dead_letter", error_code: "authentication_failed"} = Repo.reload(auth)

    exhausted = insert_event(aggregate_version: 40, attempt_count: 7)

    Application.put_env(
      :tymeslot,
      :price_projection_test_response,
      response(503, "secret raw body")
    )

    assert :ok = perform()

    assert %{state: "dead_letter", error_code: "retry_exhausted_http_5xx"} =
             Repo.reload(exhausted)
  end

  test "reclaims a stale delivering row after a crash and reconciles by event ID and version" do
    event = insert_event()
    [claimed] = ProjectionOutbox.claim_due(1, ~U[2026-08-17 19:00:01Z])
    assert claimed.state == "delivering"

    Repo.update_all(
      from(row in ProjectionOutboxSchema, where: row.id == ^event.id),
      set: [updated_at: ~U[2026-08-17 19:50:00Z]]
    )

    Application.put_env(
      :tymeslot,
      :price_projection_test_response,
      response(200, ~s({"status":"duplicate"}))
    )

    assert :ok = perform()
    assert Repo.reload(event).state == "delivered"
    assert_receive {:price_projection_request, _, body, _, _}
    assert Jason.decode!(body)["eventId"] == event.event_id
    assert Jason.decode!(body)["aggregateVersion"] == 2
  end

  test "a client crash leaves the row reclaimable and never changes the committed service price" do
    owner = insert(:user)

    meeting_type =
      insert(:meeting_type,
        user: owner,
        service_id: "online-consultation",
        service_price_cents: 14_000,
        service_currency: "usd",
        event_type_version: 1
      )

    assert {:ok, updated, event} =
             PriceProjection.publish(meeting_type.id, owner.id, 1, 15_000, "usd")

    Application.put_env(
      :tymeslot,
      :price_projection_now,
      DateTime.add(event.occurred_at, 1, :second)
    )

    Application.put_env(:tymeslot, :price_projection_test_response, {:raise, "worker crashed"})

    assert_raise RuntimeError, "worker crashed", &perform/0
    assert Repo.reload(event).state == "delivering"
    assert Repo.reload(updated).service_price_cents == 15_000
    assert Repo.reload(updated).event_type_version == 2
  end

  test "oversized and invalid event payloads are never transmitted" do
    oversized = insert_event()

    Repo.update_all(
      from(row in ProjectionOutboxSchema, where: row.id == ^oversized.id),
      set: [payload: Map.put(oversized.payload, "service_id", String.duplicate("x", 17_000))]
    )

    assert :ok = perform()
    refute_receive {:price_projection_request, _, _, _, _}
    assert %{state: "dead_letter", error_code: "invalid_payload"} = Repo.reload(oversized)
  end

  test "retries an oversized response without storing its body" do
    event = insert_event()

    Application.put_env(
      :tymeslot,
      :price_projection_test_response,
      response(200, String.duplicate("private response", 2_000))
    )

    assert :ok = perform()
    assert %{state: "pending", error_code: "invalid_response"} = Repo.reload(event)
  end

  test "does not claim or send non-price event families" do
    event = insert_event()

    Repo.update_all(
      from(row in ProjectionOutboxSchema, where: row.id == ^event.id),
      set: [event_type: "booking.confirmed.v1"]
    )

    assert :ok = perform()
    refute_receive {:price_projection_request, _, _, _, _}
    assert Repo.reload(event).state == "pending"
    assert Repo.reload(event).attempt_count == 0
  end

  defp perform, do: DeliverPriceProjection.perform(%Oban.Job{args: %{}})

  defp insert_event(overrides \\ []) do
    event_id = Ecto.UUID.generate()
    occurred_at = ~U[2026-08-17 19:00:00Z]
    aggregate_version = Keyword.get(overrides, :aggregate_version, 2)

    attrs = %{
      event_id: event_id,
      event_type: "service.price_published.v1",
      schema_version: 1,
      aggregate_type: "meeting_type",
      aggregate_id: Integer.to_string(aggregate_version),
      aggregate_version: aggregate_version,
      occurred_at: occurred_at,
      attempt_count: Keyword.get(overrides, :attempt_count, 0),
      payload: %{
        "event_id" => event_id,
        "service_id" => "online-consultation",
        "cents" => 14_500,
        "currency" => "usd",
        "event_type_version" => 2,
        "aggregate_version" => aggregate_version,
        "occurred_at" => DateTime.to_iso8601(occurred_at),
        "schema_version" => 1
      }
    }

    {:ok, {:ok, event}} = Repo.transaction(fn -> ProjectionOutbox.append(attrs) end)
    event
  end

  defp response(status, body, headers \\ []),
    do: {:ok, %{status: status, body: body, headers: headers}}

  defp header(headers, name), do: headers |> Enum.into(%{}) |> Map.fetch!(name)
  defp config_value(:price_projection_url), do: @url
  defp config_value(:price_projection_secret), do: @secret
end
