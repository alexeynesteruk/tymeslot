defmodule TymeslotWeb.FollowUpLive do
  @moduledoc "Private, single-purpose booking page for included follow-ups."

  use TymeslotWeb, :live_view

  alias Tymeslot.MyPawTrainer.FollowUps

  @contact_email "mypawtrainer@gmail.com"

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(:token, token)
     |> assign(:contact_email, @contact_email)
     |> assign(:state, resolve_state(token))}
  end

  @impl true
  def handle_event("book", %{"follow_up" => params}, socket) do
    with {:ok, entitlement, _link} <- FollowUps.resolve(socket.assigns.token),
         {:ok, starts_at} <- parse_start(params, entitlement.meeting_timezone),
         {:ok, meeting} <- FollowUps.redeem(socket.assigns.token, %{start_time: starts_at}) do
      {:noreply, assign(socket, :state, {:booked, meeting})}
    else
      {:error, reason} -> {:noreply, assign(socket, :state, public_state(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-xl px-6 py-16 text-slate-900">
      <%= case @state do %>
        <% {:valid, _entitlement} -> %>
          <section aria-labelledby="follow-up-heading">
            <p class="text-sm font-semibold uppercase tracking-wide text-amber-700">My Paw Trainer</p>
            <h1 id="follow-up-heading" class="mt-2 text-3xl font-semibold">Included follow-up</h1>
            <p class="mt-4 text-lg">Choose a time for your included 30-minute virtual appointment.</p>
            <form id="follow-up-form" phx-submit="book" class="mt-8 space-y-5">
              <label class="block">
                <span class="block font-medium">Date</span>
                <input
                  type="date"
                  name="follow_up[date]"
                  required
                  class="mt-2 w-full rounded border p-3"
                />
              </label>
              <label class="block">
                <span class="block font-medium">Time</span>
                <input
                  type="time"
                  name="follow_up[time]"
                  required
                  class="mt-2 w-full rounded border p-3"
                />
              </label>
              <button type="submit" class="rounded bg-slate-900 px-5 py-3 font-semibold text-white">
                Book follow-up
              </button>
            </form>
          </section>
        <% {:booked, _meeting} -> %>
          <section aria-live="polite">
            <h1 class="text-3xl font-semibold">Your follow-up is booked</h1>
            <p class="mt-2">
              Questions? Contact <a href={"mailto:#{@contact_email}"}>{@contact_email}</a>.
            </p>
          </section>
        <% :not_yet_open -> %>
          <section>
            <h1 class="text-3xl font-semibold">This follow-up link is not open yet</h1>
            <p class="mt-4">Please return during the booking window shown in your message.</p>
          </section>
        <% :expired -> %>
          <section>
            <h1 class="text-3xl font-semibold">This follow-up link has expired</h1>
            <p class="mt-4">Contact <a href={"mailto:#{@contact_email}"}>{@contact_email}</a>.</p>
          </section>
        <% :used -> %>
          <section>
            <h1 class="text-3xl font-semibold">This follow-up link has already been used</h1>
            <p class="mt-4">
              Contact <a href={"mailto:#{@contact_email}"}>{@contact_email}</a> if you need help.
            </p>
          </section>
        <% :invalid -> %>
          <section>
            <h1 class="text-3xl font-semibold">This follow-up link is unavailable</h1>
            <p class="mt-4">
              Contact <a href={"mailto:#{@contact_email}"}>{@contact_email}</a> if you need help.
            </p>
          </section>
      <% end %>
    </main>
    """
  end

  defp resolve_state(token) do
    case FollowUps.resolve(token) do
      {:ok, entitlement, _link} -> {:valid, entitlement}
      {:error, reason} -> public_state(reason)
    end
  end

  defp public_state(reason) when reason in [:not_yet_open, :expired, :used], do: reason
  defp public_state(_reason), do: :invalid

  defp parse_start(%{"date" => date, "time" => time}, timezone) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, local} <- DateTime.new(date, time, timezone) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC") |> DateTime.truncate(:second)}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp parse_start(_params, _timezone), do: {:error, :invalid}
end
