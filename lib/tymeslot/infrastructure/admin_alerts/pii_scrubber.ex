defmodule Tymeslot.Infrastructure.AdminAlerts.PIIScrubber do
  @moduledoc """
  Masks personal data in admin alert payloads at the notifier boundary.

  Two layers of defence:

  1. **Denylisted keys** — keys known to carry email addresses are either
     rewritten to a masked variant (`owner_email` → `owner_email_masked`
     with value `a***@example.com`) or dropped entirely if the value is
     not a valid email.

  2. **Regex sweep** — every remaining string value in the payload is
     scanned for embedded email addresses and masked in place, catching
     cases where an email slipped into a `summary`, `reason_message`, or
     other free-form field.

  The scrubber is idempotent: running it on already-masked data is a
  no-op. It walks nested maps and lists so private fields cannot bypass the
  boundary by being attached under a request or context key.

  Internal IDs (`user_id`, `meeting_id`, `dispute_id`, `charge_id`,
  `customer_id`, `event_id`, `integration_id`) are left visible — they
  are how operators pivot from an alert to a database record or a
  Stripe dashboard entry.
  """

  @pii_keys ~w(owner_email customer_email email user_email recipient_email)a
  @pii_key_strings Enum.map(@pii_keys, &Atom.to_string/1)
  @private_keys ~w(
    attendee_name attendee_email attendee_phone dog_name zip_code main_concern
    brief_context desired_result setup_intent payment_method card
  )a
  @private_key_strings Enum.map(@private_keys, &Atom.to_string/1)

  # Compile-time map from PII atom key → masked atom key, avoiding dynamic
  # atom creation at runtime.
  @masked_atom_keys Map.new(@pii_keys, fn key ->
                      masked = String.to_atom("#{key}_masked")
                      {key, masked}
                    end)

  # Matches an email address embedded anywhere in a string.
  @email_regex ~r/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*(@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/
  @card_regex ~r/\b(?:\d[ -]*?){13,19}\b/

  @spec scrub(map()) :: map()
  def scrub(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, &scrub_entry/2)
  end

  defp scrub_entry({key, value}, acc) do
    cond do
      private?(key) -> acc
      denylisted?(key) -> handle_denylisted(acc, key, value)
      is_struct(value) -> Map.put(acc, key, value)
      is_map(value) -> Map.put(acc, key, scrub(value))
      is_list(value) -> Map.put(acc, key, Enum.map(value, &scrub_value/1))
      is_binary(value) -> Map.put(acc, key, sweep_string(value))
      true -> Map.put(acc, key, value)
    end
  end

  defp denylisted?(key) when is_atom(key), do: key in @pii_keys
  defp denylisted?(key) when is_binary(key), do: key in @pii_key_strings
  defp denylisted?(_key), do: false

  defp private?(key) when is_atom(key), do: key in @private_keys
  defp private?(key) when is_binary(key), do: key in @private_key_strings
  defp private?(_key), do: false

  defp handle_denylisted(acc, key, value) when is_binary(value) do
    case mask_email(String.trim(value)) do
      nil -> acc
      masked -> Map.put(acc, masked_key(key), masked)
    end
  end

  defp handle_denylisted(acc, _key, _value), do: acc

  defp masked_key(key) when is_atom(key), do: Map.fetch!(@masked_atom_keys, key)
  defp masked_key(key) when is_binary(key), do: key <> "_masked"

  defp scrub_value(value) when is_struct(value), do: value
  defp scrub_value(value) when is_map(value), do: scrub(value)
  defp scrub_value(value) when is_binary(value), do: sweep_string(value)
  defp scrub_value(value), do: value

  defp sweep_string(string) do
    masked_emails =
      Regex.replace(@email_regex, string, fn _full, first_char, domain ->
        "#{first_char}***#{domain}"
      end)

    Regex.replace(@card_regex, masked_emails, "[REDACTED CARD]")
  end

  defp mask_email(value) do
    case Regex.run(@email_regex, value) do
      [full, first_char, domain] when full == value ->
        "#{first_char}***#{domain}"

      _no_match ->
        nil
    end
  end
end
