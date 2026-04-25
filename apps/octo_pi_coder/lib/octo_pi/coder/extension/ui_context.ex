defmodule OctoPi.Coder.Extension.UIContext do
  @moduledoc false

  @type select_option :: %{label: String.t(), value: term()}

  @type custom_tui :: %{request_render: (-> :ok)}
  @type custom_theme :: %{fg: (atom(), String.t() -> String.t())}
  @type custom_component :: %{render: (pos_integer() -> [String.t()]), handle_input: (term() -> :ok)}
  @type custom_factory :: (custom_tui(), custom_theme(), (term() -> :ok) -> custom_component())

  @type t :: %__MODULE__{
          select: ([select_option()], keyword() -> {:ok, term()} | :cancelled | no_return()),
          confirm: (String.t(), keyword() -> boolean() | no_return()),
          input: (String.t(), keyword() -> {:ok, String.t()} | :cancelled | no_return()),
          notify: (String.t() -> :ok | no_return()),
          set_status: (String.t(), String.t() | nil -> :ok | no_return()),
          set_working_message: (String.t() | nil -> :ok | no_return()),
          set_working_indicator: (boolean() -> :ok | no_return()),
          set_hidden_thinking_label: (String.t() | nil -> :ok | no_return()),
          set_widget: (term() -> :ok | no_return()),
          set_footer: (term() -> :ok | no_return()),
          set_header: (term() -> :ok | no_return()),
          set_title: (String.t() -> :ok | no_return()),
          custom: (custom_factory(), keyword() -> term() | no_return()),
          paste_to_editor: (String.t() -> :ok | no_return()),
          set_editor_text: (String.t() -> :ok | no_return()),
          get_editor_text: (-> String.t() | no_return()),
          editor: (String.t(), keyword() -> {:ok, String.t()} | :cancelled | no_return()),
          add_autocomplete_provider: ((String.t() -> [String.t()]) -> :ok | no_return()),
          set_editor_component: (term() -> :ok | no_return()),
          get_all_themes: (-> [String.t()] | no_return()),
          get_theme: (-> String.t() | no_return()),
          set_theme: (String.t() -> :ok | no_return()),
          get_tools_expanded: (-> boolean() | no_return()),
          set_tools_expanded: (boolean() -> :ok | no_return()),
          apply_fg: (atom(), String.t() -> String.t() | no_return()),
          apply_bg: (atom(), String.t() -> String.t() | no_return())
        }

  @one_arity_fields [
    :notify,
    :set_working_message,
    :set_working_indicator,
    :set_hidden_thinking_label,
    :set_widget,
    :set_footer,
    :set_header,
    :set_title,
    :paste_to_editor,
    :set_editor_text,
    :add_autocomplete_provider,
    :set_editor_component,
    :set_theme,
    :set_tools_expanded
  ]

  @zero_arity_fields [
    :get_editor_text,
    :get_all_themes,
    :get_theme,
    :get_tools_expanded
  ]

  @two_arity_fields [:set_status, :custom, :editor, :confirm, :apply_fg, :apply_bg]

  @var_arity_fields [:select, :input]

  @all_fields @one_arity_fields ++ @zero_arity_fields ++ @two_arity_fields ++ @var_arity_fields

  defstruct Enum.map(@all_fields, &{&1, nil})

  @dialyzer {:no_return, new: 0}
  @spec new() :: t()
  def new do
    stubs =
      @one_arity_fields
      |> Map.new(fn f -> {f, fn _ -> stub_raise(f) end} end)
      |> Map.merge(Map.new(@zero_arity_fields, fn f -> {f, fn -> stub_raise(f) end} end))
      |> Map.merge(Map.new(@two_arity_fields, fn f -> {f, fn _, _ -> stub_raise(f) end} end))
      |> Map.merge(Map.new(@var_arity_fields, fn f -> {f, fn _, _ -> stub_raise(f) end} end))

    struct!(__MODULE__, stubs)
  end

  @spec bind(t(), map()) :: t()
  def bind(%__MODULE__{} = ctx, impls) do
    Enum.reduce(@all_fields, ctx, fn field, ctx ->
      case Map.get(impls, field) do
        nil -> ctx
        fun -> Map.put(ctx, field, fun)
      end
    end)
  end

  @spec stub_raise(atom()) :: no_return()
  defp stub_raise(field) do
    raise RuntimeError, "UIContext.#{field} not bound — no UI available"
  end
end
