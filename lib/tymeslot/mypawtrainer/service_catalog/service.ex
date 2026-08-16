defmodule Tymeslot.MyPawTrainer.Service do
  @moduledoc "Immutable code-owned identity for a My Paw Trainer service."

  @enforce_keys [:id, :name, :duration_minutes, :delivery_mode, :direct_bookable]
  defstruct [
    :id,
    :name,
    :duration_minutes,
    :delivery_mode,
    :direct_bookable,
    :intake_kind,
    :initial_price_cents,
    :route,
    :cta
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          duration_minutes: pos_integer() | nil,
          delivery_mode: String.t(),
          direct_bookable: boolean(),
          intake_kind: atom() | nil,
          initial_price_cents: pos_integer() | nil,
          route: String.t() | nil,
          cta: String.t() | nil
        }
end
