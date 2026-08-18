defmodule Tymeslot.MyPawTrainer.Workers.DeliverCrmProjection do
  @moduledoc "Delivers signed booking projections asynchronously to EspoCRM."

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 30]

  alias Tymeslot.MyPawTrainer.EspoCRMClient
  alias Tymeslot.MyPawTrainer.ProjectionOutbox

  @event_types ~w(booking.confirmed.v1 booking.rescheduled.v1 booking.completed.v1 booking.cancelled.v1 booking.expired.v1)
  @destination_path "/api/v1/tymeslot/booking-projection"
  @request_limit 16 * 1024
  @response_limit 16 * 1024
  @timeout 5_000
  @max_attempts 8
  @max_backoff 3_600
  @projection_keys MapSet.new(
                     ~w(booking_id service_id service_name appointment_start appointment_end time_zone delivery_mode booking_state aggregate_version last_sync_time operator_deep_link)
                   )

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case configuration() do
      :disabled ->
        :ok

      {:ok, config} ->
        now = now()

        Enum.each(
          @event_types,
          &ProjectionOutbox.reclaim_stale(DateTime.add(now, -300, :second), &1)
        )

        Enum.each(@event_types, fn type ->
          25 |> ProjectionOutbox.claim_due(now, type) |> Enum.each(&deliver(&1, config, now))
        end)

        :ok
    end
  end

  defp deliver(event, config, now) do
    with {:ok, body} <- encode_body(event),
         :ok <- validate_url(config.url),
         {:ok, timestamp, nonce} <- signing_values(now),
         headers = signed_headers(body, event.event_id, timestamp, nonce, config.secret),
         outcome <- classify(config.client.post(config.url, body, headers, request_options())),
         outcome <- reconcile_uncertain(outcome, event, config, timestamp, nonce) do
      transition(event, outcome, now)
    else
      {:error, code} when code in [:invalid_payload, :invalid_url, :invalid_nonce] ->
        ProjectionOutbox.dead_letter(event.id, Atom.to_string(code))
    end
  end

  defp encode_body(%{
         event_type: type,
         payload: payload,
         event_id: event_id,
         aggregate_version: version
       })
       when type in @event_types and is_map(payload) do
    body = %{
      "type" => type,
      "schemaVersion" => 1,
      "eventId" => event_id,
      "aggregateVersion" => version,
      "projection" => payload
    }

    encoded = Jason.encode!(body)

    if valid_projection?(payload, event_id, version, type) and
         byte_size(encoded) <= @request_limit,
       do: {:ok, encoded},
       else: {:error, :invalid_payload}
  end

  defp encode_body(_event), do: {:error, :invalid_payload}

  defp valid_projection?(payload, event_id, version, type) do
    state = type |> String.split(".") |> Enum.at(1)

    MapSet.new(Map.keys(payload)) == @projection_keys and
      is_binary(payload["booking_id"]) and
      payload["aggregate_version"] == version and
      payload["booking_state"] == state and
      is_binary(event_id)
  end

  defp validate_url(url) do
    uri = URI.parse(url)

    if uri.path == @destination_path and is_binary(uri.host) and uri.host != "" and
         (uri.scheme == "https" or Application.get_env(:tymeslot, :environment) == :test),
       do: :ok,
       else: {:error, :invalid_url}
  end

  defp signing_values(now) do
    nonce =
      Application.get_env(:tymeslot, :crm_projection_nonce) ||
        :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

    if is_binary(nonce) and byte_size(nonce) in 16..128,
      do: {:ok, DateTime.to_iso8601(now), nonce},
      else: {:error, :invalid_nonce}
  end

  defp signed_headers(body, event_id, timestamp, nonce, secret) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    input = Enum.join([timestamp, nonce, event_id, digest], "\n")
    signature = :crypto.mac(:hmac, :sha256, secret, input) |> Base.encode16(case: :lower)

    [
      {"content-type", "application/json"},
      {"x-mpt-timestamp", timestamp},
      {"x-mpt-nonce", nonce},
      {"x-mpt-event-id", event_id},
      {"x-mpt-signature", signature},
      {"idempotency-key", event_id}
    ]
  end

  defp classify({:ok, %{status: status, body: body}}) when status in 200..299 do
    case decode(body) do
      %{"status" => value} when value in ["applied", "duplicate"] -> :delivered
      _ -> {:retry, "invalid_response", nil}
    end
  end

  defp classify({:ok, %{status: status}}) when status in [401, 403],
    do: {:dead_letter, "authentication_failed"}

  defp classify({:ok, %{status: 409, body: body}}) do
    case decode(body) do
      %{"error" => "older_aggregate_version"} -> :delivered
      %{"error" => "uncertain_create"} -> :uncertain
      _ -> {:retry, "invalid_response", nil}
    end
  end

  defp classify({:ok, %{status: 408}}), do: {:retry, "http_408", nil}
  defp classify({:ok, %{status: 429} = response}), do: {:retry, "http_429", retry_after(response)}
  defp classify({:ok, %{status: status}}) when status in 500..599, do: {:retry, "http_5xx", nil}
  defp classify({:error, %Req.TransportError{reason: :timeout}}), do: {:retry, "timeout", nil}
  defp classify({:error, _}), do: {:retry, "transport_error", nil}
  defp classify(_), do: {:retry, "invalid_response", nil}

  defp reconcile_uncertain(:uncertain, event, config, timestamp, nonce) do
    body =
      Jason.encode!(%{
        "bookingId" => event.aggregate_id,
        "aggregateVersion" => event.aggregate_version
      })

    headers = signed_headers(body, event.event_id, timestamp, nonce, config.secret)

    case config.client.reconcile(config.url <> "/reconcile", body, headers, request_options()) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        case decode(response) do
          %{"status" => value} when value in ["current", "newer", "duplicate"] -> :delivered
          _ -> {:retry, "uncertain_create", nil}
        end

      _ ->
        {:retry, "uncertain_create", nil}
    end
  end

  defp reconcile_uncertain(outcome, _event, _config, _timestamp, _nonce), do: outcome

  defp transition(event, :delivered, now), do: ProjectionOutbox.mark_delivered(event.id, now)

  defp transition(event, {:dead_letter, code}, _now),
    do: ProjectionOutbox.dead_letter(event.id, code)

  defp transition(event, {:retry, code, retry_after}, now) do
    if event.attempt_count >= @max_attempts do
      ProjectionOutbox.dead_letter(event.id, "retry_exhausted_" <> code)
    else
      delay = min(retry_after || retry_backoff(event.attempt_count), @max_backoff)
      ProjectionOutbox.reschedule_retry(event.id, code, DateTime.add(now, delay, :second))
    end
  end

  defp retry_backoff(attempt) do
    base = min(Integer.pow(2, attempt), @max_backoff)
    jitter = Application.get_env(:tymeslot, :crm_projection_jitter, :random)
    if is_integer(jitter), do: min(base + max(jitter, 0), @max_backoff), else: base
  end

  defp retry_after(%{headers: headers}) do
    value =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(to_string(key)) == "retry-after", do: List.wrap(value) |> List.first()
      end)

    case Integer.parse(to_string(value || "")) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp retry_after(_), do: nil

  defp decode(body) when is_binary(body) and byte_size(body) <= @response_limit do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) and map_size(value) == 1 -> value
      _ -> nil
    end
  end

  defp decode(_), do: nil

  defp request_options,
    do: [timeout: @timeout, max_response_bytes: @response_limit, redirect: false]

  defp configuration do
    enabled = Application.get_env(:tymeslot, :crm_projection_delivery_enabled, false)
    url = Application.get_env(:tymeslot, :crm_projection_url)
    secret = Application.get_env(:tymeslot, :crm_projection_secret)

    if enabled and present?(url) and present?(secret),
      do:
        {:ok,
         %{
           url: url,
           secret: secret,
           client: Application.get_env(:tymeslot, :crm_projection_http_client, EspoCRMClient)
         }},
      else: :disabled
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp now, do: Application.get_env(:tymeslot, :crm_projection_now) || DateTime.utc_now(:second)
end
