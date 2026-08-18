defmodule Tymeslot.MyPawTrainer.Workers.DeliverPriceProjection do
  @moduledoc "Delivers signed direct-service price projections without blocking price changes."

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 30]

  alias Tymeslot.MyPawTrainer.ProjectionHTTPClient
  alias Tymeslot.MyPawTrainer.ProjectionOutbox

  @event_type "service.price_published.v1"
  @direct_services ~w(discovery-call online-consultation in-home-consultation)
  @request_body_limit 16 * 1024
  @response_body_limit 16 * 1024
  @timeout 5_000
  @max_attempts 8
  @max_backoff_seconds 3_600
  @destination_path "/api/internal/tymeslot/service-price/v1"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case configuration() do
      :disabled ->
        :ok

      {:ok, config} ->
        now = now()
        ProjectionOutbox.reclaim_stale(DateTime.add(now, -300, :second), @event_type)

        25
        |> ProjectionOutbox.claim_due(now, @event_type)
        |> Enum.each(&deliver(&1, config, now))

        :ok
    end
  end

  defp deliver(event, config, now) do
    with {:ok, body} <- encode_body(event),
         :ok <- validate_url(config.url),
         {:ok, timestamp, nonce} <- signing_values(now),
         headers <- signed_headers(body, event.event_id, timestamp, nonce, config.secret),
         result <- config.client.post(config.url, body, headers, request_options()),
         outcome <- classify(result) do
      transition(event, outcome, now)
    else
      {:error, code} when code in [:invalid_payload, :invalid_url, :invalid_nonce] ->
        ProjectionOutbox.dead_letter(event.id, Atom.to_string(code))
    end
  end

  defp encode_body(%{event_type: @event_type, payload: payload} = event) when is_map(payload) do
    body = %{
      "type" => @event_type,
      "schemaVersion" => payload["schema_version"],
      "eventId" => payload["event_id"],
      "serviceId" => payload["service_id"],
      "cents" => payload["cents"],
      "currency" => payload["currency"],
      "eventTypeVersion" => payload["event_type_version"],
      "aggregateVersion" => payload["aggregate_version"],
      "occurredAt" => payload["occurred_at"],
      "routeCompatible" => true
    }

    if valid_body?(body, event) do
      encoded = Jason.encode!(body)

      if byte_size(encoded) <= @request_body_limit,
        do: {:ok, encoded},
        else: {:error, :invalid_payload}
    else
      {:error, :invalid_payload}
    end
  end

  defp encode_body(_event), do: {:error, :invalid_payload}

  defp valid_body?(body, event) do
    body["schemaVersion"] == 1 and
      body["eventId"] == event.event_id and
      valid_event_id?(body["eventId"]) and
      body["serviceId"] in @direct_services and
      is_integer(body["cents"]) and body["cents"] > 0 and body["cents"] <= 1_000_000 and
      body["currency"] == "usd" and
      is_integer(body["eventTypeVersion"]) and body["eventTypeVersion"] > 0 and
      body["aggregateVersion"] == event.aggregate_version and
      is_integer(body["aggregateVersion"]) and body["aggregateVersion"] > 0 and
      valid_occurred_at?(body["occurredAt"])
  end

  defp valid_event_id?(value) when is_binary(value) do
    byte_size(value) in 6..128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{5,127}\z/, value)
  end

  defp valid_event_id?(_value), do: false

  defp valid_occurred_at?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_occurred_at?(_value), do: false

  defp validate_url(url) do
    uri = URI.parse(url)

    if uri.path == @destination_path and is_binary(uri.host) and uri.host != "" and
         (uri.scheme == "https" or Application.get_env(:tymeslot, :environment) == :test) do
      :ok
    else
      {:error, :invalid_url}
    end
  end

  defp signing_values(now) do
    timestamp = DateTime.to_iso8601(now)

    nonce =
      Application.get_env(:tymeslot, :price_projection_nonce) ||
        :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

    if is_binary(nonce) and byte_size(nonce) in 16..128 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{15,127}\z/, nonce) do
      {:ok, timestamp, nonce}
    else
      {:error, :invalid_nonce}
    end
  end

  defp signed_headers(body, event_id, timestamp, nonce, secret) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    signing_input = timestamp <> "\n" <> nonce <> "\n" <> event_id <> "\n" <> digest
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input) |> Base.encode16(case: :lower)

    [
      {"content-type", "application/json"},
      {"x-mpt-timestamp", timestamp},
      {"x-mpt-nonce", nonce},
      {"x-mpt-event-id", event_id},
      {"x-mpt-signature", signature},
      {"idempotency-key", event_id}
    ]
  end

  defp request_options do
    [timeout: @timeout, max_response_bytes: @response_body_limit, redirect: false]
  end

  defp classify({:ok, %{status: status, body: body}}) when status in 200..299 do
    case decode_response(body) do
      %{"status" => status} when status in ["applied", "duplicate"] -> :delivered
      _other -> {:retry, "invalid_response", nil}
    end
  end

  defp classify({:ok, %{status: status}}) when status in [401, 403],
    do: {:dead_letter, "authentication_failed"}

  defp classify({:ok, %{status: 409, body: body}}) do
    case decode_response(body) do
      %{"error" => "stale_projection"} -> :delivered
      _other -> {:retry, "invalid_response", nil}
    end
  end

  defp classify({:ok, %{status: 408}}), do: {:retry, "http_408", nil}

  defp classify({:ok, %{status: 429} = response}),
    do: {:retry, "http_429", retry_after(response)}

  defp classify({:ok, %{status: status}}) when status in 500..599,
    do: {:retry, "http_5xx", nil}

  defp classify({:ok, _response}), do: {:retry, "invalid_response", nil}
  defp classify({:error, %Req.TransportError{reason: :timeout}}), do: {:retry, "timeout", nil}
  defp classify({:error, _reason}), do: {:retry, "transport_error", nil}
  defp classify(_result), do: {:retry, "invalid_response", nil}

  defp decode_response(body) when is_binary(body) and byte_size(body) <= @response_body_limit do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) and map_size(value) == 1 -> value
      _other -> nil
    end
  end

  defp decode_response(_body), do: nil

  defp retry_after(%{headers: headers}) do
    headers
    |> normalize_headers()
    |> Map.get("retry-after")
    |> parse_retry_after()
  end

  defp retry_after(_response), do: nil

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} ->
      {String.downcase(to_string(key)), List.wrap(value) |> List.first()}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} ->
      {String.downcase(to_string(key)), List.wrap(value) |> List.first()}
    end)
  end

  defp normalize_headers(_headers), do: %{}

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds
      _other -> nil
    end
  end

  defp parse_retry_after(_value), do: nil

  defp transition(event, :delivered, now), do: ProjectionOutbox.mark_delivered(event.id, now)

  defp transition(event, {:dead_letter, code}, _now),
    do: ProjectionOutbox.dead_letter(event.id, code)

  defp transition(event, {:retry, code, retry_after}, now) do
    if event.attempt_count >= @max_attempts do
      ProjectionOutbox.dead_letter(event.id, "retry_exhausted_" <> code)
    else
      seconds = retry_after || exponential_backoff(event.attempt_count)
      next_attempt_at = DateTime.add(now, min(seconds, @max_backoff_seconds), :second)
      ProjectionOutbox.reschedule_retry(event.id, code, next_attempt_at)
    end
  end

  defp exponential_backoff(attempt) do
    base = min(Integer.pow(2, attempt), @max_backoff_seconds)
    jitter_limit = max(div(base, 4), 1)

    jitter =
      case Application.get_env(:tymeslot, :price_projection_jitter) do
        value when is_integer(value) and value >= 0 -> min(value, jitter_limit)
        _other -> :rand.uniform(jitter_limit) - 1
      end

    min(base + jitter, @max_backoff_seconds)
  end

  defp configuration do
    enabled? = Application.get_env(:tymeslot, :price_projection_delivery_enabled, false)
    url = Application.get_env(:tymeslot, :price_projection_url)
    secret = Application.get_env(:tymeslot, :price_projection_secret)

    if enabled? and present?(url) and present?(secret) do
      {:ok,
       %{
         url: url,
         secret: secret,
         client:
           Application.get_env(
             :tymeslot,
             :price_projection_http_client,
             ProjectionHTTPClient
           )
       }}
    else
      :disabled
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp now do
    Application.get_env(:tymeslot, :price_projection_now) || DateTime.utc_now(:second)
  end
end
