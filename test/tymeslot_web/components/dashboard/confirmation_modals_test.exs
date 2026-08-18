defmodule TymeslotWeb.Components.Dashboard.ConfirmationModalsTest do
  use TymeslotWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Meetings.CompleteMeetingModal
  alias TymeslotWeb.Dashboard.PaymentsSettings.ChargeModal

  test "complete confirmation uses the shared visible modal shell" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <CompleteMeetingModal.complete_meeting_modal
            meeting={@meeting}
            show={true}
            target={@target}
          />
          """
        end,
        %{
          meeting: %{
            attendee_name: "Complete Flow Test",
            start_time: ~U[2026-08-18 16:38:42Z]
          },
          target: nil
        }
      )

    assert html =~ ~s(id="complete-meeting-modal")
    assert html =~ "modal-overlay"
    assert html =~ ~s(phx-hook="ModalFocusTrap")
    assert html =~ ~s(aria-labelledby="complete-meeting-modal-title")
    assert html =~ "Mark completed"
    assert html =~ "Cancel"
  end

  test "charge confirmation uses the shared visible modal shell" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <ChargeModal.charge_modal payment={@payment} show={true} target={@target} />
          """
        end,
        %{
          payment: %{
            id: "payment-id",
            attendee_name: "Complete Flow Test",
            meeting: %{start_time: ~U[2026-08-18 16:38:42Z]},
            service_snapshot: %{
              "service_name" => "Discovery call",
              "amount_cents" => 4_900,
              "currency" => "usd"
            }
          },
          target: nil
        }
      )

    assert html =~ ~s(id="charge-payment-modal")
    assert html =~ "modal-overlay"
    assert html =~ ~s(phx-hook="ModalFocusTrap")
    assert html =~ ~s(aria-labelledby="charge-payment-modal-title")
    assert html =~ "Confirm charge"
    assert html =~ "Cancel"
  end
end
