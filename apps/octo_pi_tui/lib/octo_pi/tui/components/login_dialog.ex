defmodule OctoPi.TUI.Components.LoginDialog do
  @moduledoc false

  alias OctoPi.TUI.Components.Box
  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @type t :: %__MODULE__{
          value: String.t(),
          theme: Theme.t(),
          provider: String.t(),
          error: String.t() | nil
        }

  defstruct [:theme, value: "", provider: "API Provider", error: nil]

  @spec new(Theme.t(), keyword()) :: t()
  def new(theme, opts \\ []) do
    %__MODULE__{
      theme: theme,
      provider: Keyword.get(opts, :provider, "API Provider")
    }
  end

  @spec handle_char(t(), String.t()) :: t()
  def handle_char(%__MODULE__{value: v} = d, char) do
    %{d | value: v <> char, error: nil}
  end

  def handle_key(%__MODULE__{} = d, %Key{key: :escape}), do: {d, [:cancel]}

  def handle_key(%__MODULE__{value: v} = d, %Key{key: :backspace}) do
    trimmed = String.slice(v, 0, max(String.length(v) - 1, 0))
    {%{d | value: trimmed, error: nil}, []}
  end

  def handle_key(%__MODULE__{value: ""} = d, %Key{key: :enter}) do
    {%{d | error: "API key cannot be empty"}, []}
  end

  def handle_key(%__MODULE__{value: v} = d, %Key{key: :enter}) do
    if valid_api_key?(v) do
      {d, [{:api_key_entered, v}]}
    else
      {%{d | error: "Invalid API key format"}, []}
    end
  end

  def handle_key(%__MODULE__{} = d, %Key{}), do: {d, []}

  def render(%__MODULE__{} = d, width) do
    title = Theme.fg(d.theme, :warning, "Login to #{d.provider}")
    masked = mask_value(d.value)
    input_line = Theme.fg(d.theme, :text, "Key: #{masked}")
    hint = Theme.fg(d.theme, :muted, "Enter to submit, Escape to cancel")

    children = [
      %Text{content: title},
      %Text{content: ""},
      %Text{content: input_line}
    ]

    children =
      if d.error do
        children ++ [%Text{content: Theme.fg(d.theme, :error, d.error)}]
      else
        children
      end

    children = children ++ [%Text{content: ""}, %Text{content: hint}]

    border_color = fn text -> Theme.fg(d.theme, :border, text) end

    box =
      Box.new(
        border: true,
        title: "API Key",
        padding_x: 1,
        border_color: border_color
      )

    box = Enum.reduce(children, box, &Box.add_child(&2, &1))
    Box.render(box, width)
  end

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  defp mask_value(""), do: ""

  defp mask_value(value) do
    len = String.length(value)

    if len <= 4 do
      String.duplicate("•", len)
    else
      String.duplicate("•", len - 4) <> String.slice(value, -4, 4)
    end
  end

  defp valid_api_key?(key) do
    # Accept common API key formats (Anthropic sk-ant-*, OpenRouter sk-or-*, OpenAI sk-*, etc.)
    # Just validate minimum length to filter out obviously invalid inputs
    String.length(key) > 10
  end
end
