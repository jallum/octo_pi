defmodule OctoPi.TUI.Components.SummarizePrompt do
  @moduledoc """
  Three-way "Summarize branch?" prompt. G5c component.

  Mirrors the post-tree-selection flow in
  `tmp/pi-mono/.../interactive-mode.ts:4129-4141`.

  ## Options

    * `"No summary"`                  → `{:result, :no}`
    * `"Summarize"`                   → `{:result, :yes}`
    * `"Summarize with custom prompt"`→ `{:awaiting_custom_instructions}`
      (caller shows an editor; when done, call `complete_custom/2`)

  ## Events emitted by `handle_key/2`

    * `{:result, :no}`                        — user chose no summary
    * `{:result, :yes}`                        — user chose plain summarize
    * `{:awaiting_custom_instructions}`        — user wants custom prompt; show editor
    * `:cancel`                                — user pressed escape

  ## Mapping to `user_wants_summary`

  The caller maps events to the three-valued type used by
  `Session.navigate_tree/2`:

    * `{:result, :no}`         → `user_wants_summary: :no`
    * `{:result, :yes}`        → `user_wants_summary: :yes`
    * `{:result, {:yes, txt}}` → `user_wants_summary: {:yes, txt}`
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key

  @options ["No summary", "Summarize", "Summarize with custom prompt"]
  @count length(@options)

  @type summary_result :: :no | :yes | {:yes, String.t()}

  @type event ::
          {:result, summary_result()}
          | :awaiting_custom_instructions
          | :cancel

  @type t :: %__MODULE__{
          selected: 0..2,
          title: String.t()
        }

  defstruct selected: 0, title: "Summarize branch?"

  @doc "Build a new prompt, optionally with a custom title."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{title: Keyword.get(opts, :title, "Summarize branch?")}
  end

  @doc """
  Complete a custom-instructions flow once the editor returns `text`.
  Returns `{:result, {:yes, text}}` (the caller passes this back to the
  session as `user_wants_summary: {:yes, text}`).
  """
  @spec complete_custom(t(), String.t()) :: {t(), [{:result, {:yes, String.t()}}]}
  def complete_custom(%__MODULE__{} = state, text) when is_binary(text) do
    {state, [{:result, {:yes, text}}]}
  end

  @doc "Return the list of option labels in display order."
  @spec options() :: [String.t()]
  def options, do: @options

  @impl true
  def render(%__MODULE__{selected: sel, title: title}, _width) do
    header = ["", title, ""]

    rows =
      @options
      |> Enum.with_index()
      |> Enum.map(fn {opt, i} ->
        if i == sel, do: "> #{opt}", else: "  #{opt}"
      end)

    header ++ rows ++ [""]
  end

  @impl true
  def handle_key(%__MODULE__{selected: sel} = state, %Key{key: :up}) do
    {%{state | selected: rem(sel - 1 + @count, @count)}, []}
  end

  def handle_key(%__MODULE__{selected: sel} = state, %Key{key: :down}) do
    {%{state | selected: rem(sel + 1, @count)}, []}
  end

  def handle_key(%__MODULE__{} = state, %Key{key: :escape}) do
    {state, [:cancel]}
  end

  def handle_key(%__MODULE__{selected: sel} = state, %Key{key: :enter}) do
    event =
      case Enum.at(@options, sel) do
        "No summary" -> {:result, :no}
        "Summarize" -> {:result, :yes}
        "Summarize with custom prompt" -> :awaiting_custom_instructions
      end

    {state, [event]}
  end

  def handle_key(%__MODULE__{} = state, %Key{}), do: {state, []}

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state
end
