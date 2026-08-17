defmodule TymeslotWeb.Dashboard.Mypawtrainer.ZipAllowlistComponent do
  @moduledoc """
  Authenticated owner UI for the in-home ZIP allowlist.

  Reads and writes only the current user's rows. The public booking flow
  never renders this list.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MyPawTrainer.ZipAllowlist

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_zips()
      |> assign_new(:zip_draft, fn -> "" end)
      |> assign_new(:form_error, fn -> nil end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_zip", %{"zip_code" => zip_code}, socket) do
    apply_change(socket, zip_code, true, "Could not add that ZIP.")
  end

  def handle_event("deactivate_zip", %{"zip" => zip_code}, socket) do
    apply_change(socket, zip_code, false, "Could not deactivate that ZIP.")
  end

  def handle_event("reactivate_zip", %{"zip" => zip_code}, socket) do
    apply_change(socket, zip_code, true, "Could not reactivate that ZIP.")
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-8 pb-20" data-testid="service-area-admin">
      <.section_header
        icon="hero-map-pin"
        title={dgettext("dashboard_common", "Service area")}
      />

      <p class="text-tymeslot-600 max-w-2xl">
        {dgettext(
          "dashboard_common",
          "In-home times appear only after a visitor enters an active ZIP from this list. Changes apply to future bookings and do not cancel existing meetings."
        )}
      </p>

      <form phx-submit="add_zip" phx-target={@myself} class="flex flex-wrap items-end gap-3">
        <div>
          <label for="zip_code" class="block text-sm font-semibold text-tymeslot-800 mb-1">
            {dgettext("dashboard_common", "ZIP code")}
          </label>
          <input
            id="zip_code"
            name="zip_code"
            value={@zip_draft}
            inputmode="numeric"
            autocomplete="postal-code"
            maxlength="5"
            class="rounded-xl border-2 border-tymeslot-100 px-4 py-3 w-40"
          />
        </div>
        <button type="submit" class="btn-primary">
          {dgettext("dashboard_common", "Add ZIP")}
        </button>
      </form>

      <p :if={@form_error} class="text-red-700" role="alert">{@form_error}</p>

      <div class="card-glass overflow-hidden">
        <table class="w-full text-left">
          <thead>
            <tr class="border-b border-tymeslot-100 text-sm text-tymeslot-500">
              <th class="px-4 py-3">{dgettext("dashboard_common", "ZIP")}</th>
              <th class="px-4 py-3">{dgettext("dashboard_common", "Status")}</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@zips == []}>
              <td colspan="3" class="px-4 py-6 text-tymeslot-500">
                {dgettext("dashboard_common", "No ZIPs yet. In-home booking stays closed.")}
              </td>
            </tr>
            <tr :for={row <- @zips} class="border-t border-tymeslot-50">
              <td class="px-4 py-3 font-semibold">{row.zip_code}</td>
              <td class="px-4 py-3">
                {if row.active,
                  do: dgettext("dashboard_common", "Active"),
                  else: dgettext("dashboard_common", "Inactive")}
              </td>
              <td class="px-4 py-3 text-right">
                <button
                  :if={row.active}
                  type="button"
                  phx-click="deactivate_zip"
                  phx-value-zip={row.zip_code}
                  phx-target={@myself}
                  class="text-sm font-semibold text-tymeslot-700"
                >
                  {dgettext("dashboard_common", "Deactivate")}
                </button>
                <button
                  :if={!row.active}
                  type="button"
                  phx-click="reactivate_zip"
                  phx-value-zip={row.zip_code}
                  phx-target={@myself}
                  class="text-sm font-semibold text-turquoise-700"
                >
                  {dgettext("dashboard_common", "Reactivate")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp apply_change(socket, zip_code, active, error_message) do
    owner_id = socket.assigns.current_user.id

    case ZipAllowlist.set_active(owner_id, zip_code, active: active, actor_id: owner_id) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> assign(:zip_draft, "")
         |> assign(:form_error, nil)
         |> assign_zips()}

      {:error, :unauthorized} ->
        {:noreply, assign(socket, :form_error, "You can only manage your own service area.")}

      {:error, :invalid_zip} ->
        {:noreply, assign(socket, :form_error, "Enter a five-digit ZIP.")}

      {:error, _other} ->
        {:noreply, assign(socket, :form_error, error_message)}
    end
  end

  defp assign_zips(socket) do
    assign(socket, :zips, ZipAllowlist.list_for_owner(socket.assigns.current_user.id))
  end
end
