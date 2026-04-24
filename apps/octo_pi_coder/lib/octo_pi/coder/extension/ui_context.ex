defmodule OctoPi.Coder.Extension.UIContext do
  @moduledoc false

  @type select_option :: %{label: String.t(), value: term()}

  @type t :: %__MODULE__{
          select: ([select_option()], keyword() -> {:ok, term()} | :cancelled),
          confirm: (String.t(), keyword() -> boolean()),
          input: (String.t(), keyword() -> {:ok, String.t()} | :cancelled),
          notify: (String.t() -> :ok),
          set_status: (String.t() -> :ok),
          set_working_message: (String.t() | nil -> :ok),
          set_working_indicator: (boolean() -> :ok),
          set_hidden_thinking_label: (String.t() | nil -> :ok),
          set_widget: (term() -> :ok),
          set_footer: (term() -> :ok),
          set_header: (term() -> :ok),
          set_title: (String.t() -> :ok),
          custom: (term(), keyword() -> term()),
          paste_to_editor: (String.t() -> :ok),
          set_editor_text: (String.t() -> :ok),
          get_editor_text: (-> String.t()),
          editor: (String.t(), keyword() -> {:ok, String.t()} | :cancelled),
          add_autocomplete_provider: ((String.t() -> [String.t()]) -> :ok),
          set_editor_component: (term() -> :ok),
          get_all_themes: (-> [String.t()]),
          get_theme: (-> String.t()),
          set_theme: (String.t() -> :ok),
          get_tools_expanded: (-> boolean()),
          set_tools_expanded: (boolean() -> :ok)
        }

  @one_arity_fields [
    :notify, :set_status, :set_working_message, :set_working_indicator,
    :set_hidden_thinking_label, :set_widget, :set_footer, :set_header,
    :set_title, :paste_to_editor, :set_editor_text,
    :add_autocomplete_provider, :set_editor_component,
    :set_theme, :set_tools_expanded, :confirm
  ]

  @zero_arity_fields [
    :get_editor_text, :get_all_themes, :get_theme, :get_tools_expanded
  ]

  @two_arity_fields [:custom, :editor]

  @var_arity_fields [:select, :input]

  @all_fields @one_arity_fields ++ @zero_arity_fields ++ @two_arity_fields ++ @var_arity_fields

  defstruct Enum.map(@all_fields, &{&1, nil})

  @spec new() :: t()
  def new do
    stubs =
      Map.new(@one_arity_fields, fn f -> {f, fn _ -> stub_raise(f) end} end)
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

  defp stub_raise(field) do
    raise RuntimeError, "UIContext.#{field} not bound — no UI available"
  end
end
