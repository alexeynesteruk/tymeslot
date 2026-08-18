defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.PageFields do
  @moduledoc "Renders every field on the current custom-questions page."

  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer

  attr :definitions, :list, required: true
  attr :answers, :map, required: true
  attr :errors, :map, required: true
  attr :myself, :any, required: true
  attr :error_class, :string, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = assign(assigns, :rows, field_rows(assigns.definitions))

    ~H"""
    <div class="custom-question-fields">
      <div
        :for={row <- @rows}
        class={["custom-question-field-row", length(row) > 1 && "is-split"]}
      >
        <div :for={definition <- row} class="custom-question-field">
          <p
            :if={length(@definitions) > 1}
            class="custom-question-field-label"
          >
            {definition["label"]}
          </p>
          <InputRenderer.render
            definition={definition}
            value={Map.get(@answers, definition["id"])}
            myself={@myself}
          />
          <p :if={Map.get(@errors, definition["id"])} class={@error_class}>
            {Map.get(@errors, definition["id"])}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp field_rows(definitions) do
    Enum.chunk_by(definitions, fn definition ->
      definition["row"] || definition["id"]
    end)
  end
end
