defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Engine do
  @moduledoc """
  Pure state machine for the booker-facing custom questions wizard step.

  Holds the ordered snapshot of definitions, the booker's in-progress
  answers, per-question errors, and the current page index. Has no
  knowledge of LiveView — themes wrap the state and render one page at
  a time. Consecutive definitions that share a `group` key occupy the
  same page; ungrouped definitions stay one per page.
  """

  alias Tymeslot.CustomFields

  @type t :: %__MODULE__{
          definitions: [map()],
          pages: [[map()]],
          current_index: non_neg_integer(),
          answers: %{String.t() => any()},
          errors: %{String.t() => String.t()},
          touched: term()
        }

  defstruct definitions: [],
            pages: [],
            current_index: 0,
            answers: %{},
            errors: %{},
            touched: MapSet.new()

  @spec init([map()]) :: t()
  def init(definitions) when is_list(definitions) do
    sorted = Enum.sort_by(definitions, &position/1)
    %__MODULE__{definitions: sorted, pages: build_pages(sorted)}
  end

  @spec skipped?(t()) :: boolean()
  def skipped?(%__MODULE__{pages: []}), do: true
  def skipped?(%__MODULE__{}), do: false

  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{pages: pages}), do: length(pages)

  @spec current_definition(t()) :: map() | nil
  def current_definition(%__MODULE__{} = s) do
    case current_definitions(s) do
      [definition | _rest] -> definition
      _empty -> nil
    end
  end

  @spec current_definitions(t()) :: [map()]
  def current_definitions(%__MODULE__{pages: pages, current_index: i}) do
    Enum.at(pages, i) || []
  end

  @spec page_title(t()) :: String.t() | nil
  def page_title(%__MODULE__{} = s) do
    case current_definitions(s) do
      [%{"group_label" => label} | _rest] when is_binary(label) and label != "" ->
        label

      [%{"label" => label} | _rest] ->
        label

      _empty ->
        nil
    end
  end

  @spec answer(t(), String.t(), any()) :: t()
  def answer(%__MODULE__{} = s, id, value) do
    %{
      s
      | answers: Map.put(s.answers, id, value),
        touched: MapSet.put(s.touched, id),
        errors: Map.delete(s.errors, id)
    }
  end

  @spec next(t()) :: {:ok, t()} | {:error, t()}
  def next(%__MODULE__{pages: []} = s), do: {:error, s}

  def next(%__MODULE__{} = s) do
    case validate_current_page(s) do
      {:ok, normalised} ->
        s = %{
          s
          | answers: Map.merge(s.answers, normalised),
            errors: Map.drop(s.errors, Map.keys(normalised))
        }

        {:ok, %{s | current_index: min(s.current_index + 1, max(length(s.pages) - 1, 0))}}

      {:error, errors} ->
        {:error, %{s | errors: Map.merge(s.errors, errors)}}
    end
  end

  @spec prev(t()) :: t()
  def prev(%__MODULE__{current_index: 0} = s), do: s
  def prev(%__MODULE__{} = s), do: %{s | current_index: s.current_index - 1}

  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{pages: pages, current_index: i} = s) do
    i == length(pages) - 1 and match?({:ok, _}, validate_current_page(s))
  end

  @spec validate_all(t()) :: {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate_all(%__MODULE__{definitions: defs, answers: ans}),
    do: CustomFields.validate_answers(defs, ans)

  @spec put_errors(t(), %{String.t() => String.t()}) :: t()
  def put_errors(%__MODULE__{} = s, errors) when is_map(errors) do
    first_index =
      s.pages
      |> Enum.with_index()
      |> Enum.find_value(fn {page, index} ->
        if Enum.any?(page, &Map.has_key?(errors, &1["id"])), do: index
      end)

    %{s | errors: errors, current_index: first_index || s.current_index}
  end

  defp validate_current_page(%__MODULE__{} = s) do
    case current_definitions(s) do
      [] ->
        {:error, %{}}

      page ->
        Enum.reduce(page, {:ok, %{}}, fn definition, acc ->
          merge_page_validation(acc, definition, Map.get(s.answers, definition["id"]))
        end)
    end
  end

  defp merge_page_validation({:error, errors}, definition, value) do
    case CustomFields.validate_answer(value, definition) do
      {:ok, _normalised} -> {:error, errors}
      {:error, msg} -> {:error, Map.put(errors, definition["id"], msg)}
    end
  end

  defp merge_page_validation({:ok, normalised}, definition, value) do
    case CustomFields.validate_answer(value, definition) do
      {:ok, field_value} -> {:ok, Map.put(normalised, definition["id"], field_value)}
      {:error, msg} -> {:error, %{definition["id"] => msg}}
    end
  end

  defp build_pages(definitions) do
    {pages, last} =
      Enum.reduce(definitions, {[], nil}, fn definition, {pages, last} ->
        group = definition["group"]

        cond do
          is_binary(group) and last != nil and last["group"] == group ->
            {append_to_last_page(pages, definition), definition}

          true ->
            {pages ++ [[definition]], definition}
        end
      end)

    _ = last
    pages
  end

  defp append_to_last_page(pages, definition) do
    List.update_at(pages, -1, &(&1 ++ [definition]))
  end

  defp position(%{"position" => p}), do: p || 0
  defp position(%{position: p}), do: p || 0
  defp position(_field), do: 0
end
