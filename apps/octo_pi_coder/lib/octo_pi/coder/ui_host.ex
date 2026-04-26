defmodule OctoPi.Coder.UIHost do
  @moduledoc """
  Server-side behaviour for extension UI requests.

  A UIHost is a GenServer that responds to:
    - `GenServer.call(pid, {:ui_request, msg})` — synchronous queries and
      blocking dialogs (select, confirm, input, editor, custom).
    - `GenServer.cast(pid, {:ui_fire, msg})` — fire-and-forget mutations
      (notify, set_status, set_widget, etc.).

  `OctoPi.TUI.Interactive` is the canonical implementation for interactive
  mode. An Rpc mode implementation would encode these calls over JSONL
  stdout and await a matching response, mirroring pi-mono's
  `RpcExtensionUIContext`.

  ## Pure-state callback

  Implementing modules expose `handle_ui_request/2` as the pure core of
  their dispatch — `handle_call` and `handle_cast` delegate into it. This
  makes the logic directly testable without a running GenServer.
  """

  alias OctoPi.Coder.Extension.UIContext

  @doc """
  Handle a UI request message. Returns `{new_state, reply}` where `reply`
  is the value to return to the caller, or `:pending` if the operation
  opens a blocking dialog that will be resolved later via `GenServer.reply/2`.
  """
  @callback handle_ui_request(state :: term(), msg :: term()) :: {term(), term()}

  @doc """
  Build a `UIContext` whose closures dispatch into the GenServer at `pid`.

  Sync operations use `GenServer.call/3`; fire-and-forget operations use
  `GenServer.cast/2`. The `pid` must implement the UIHost message protocol.
  """
  @spec build_ui_context(pid()) :: UIContext.t()
  def build_ui_context(pid) do
    call = fn msg -> GenServer.call(pid, {:ui_request, msg}, 5_000) end
    cast = fn msg -> GenServer.cast(pid, {:ui_fire, msg}) end

    UIContext.bind(UIContext.new(), %{
      get_editor_text: fn -> call.(:get_editor_text) end,
      get_theme: fn -> call.(:get_theme) end,
      get_all_themes: fn -> call.(:get_all_themes) end,
      apply_fg: fn color, text -> call.({:apply_fg, color, text}) end,
      apply_bg: fn color, text -> call.({:apply_bg, color, text}) end,
      get_tools_expanded: fn -> call.(:get_tools_expanded) end,
      set_editor_text: fn text -> cast.({:set_editor_text, text}) end,
      paste_to_editor: fn text -> cast.({:paste_to_editor, text}) end,
      set_theme: fn name -> cast.({:set_theme, name}) end,
      set_tools_expanded: fn val -> cast.({:set_tools_expanded, val}) end,
      notify: fn text -> cast.({:notify, text}) end,
      set_status: fn id, text -> cast.({:set_status, id, text}) end,
      set_working_message: fn msg -> cast.({:set_working_message, msg}) end,
      set_working_indicator: fn val -> cast.({:set_working_indicator, val}) end,
      set_hidden_thinking_label: fn label -> cast.({:set_hidden_thinking_label, label}) end,
      set_widget: fn w -> cast.({:set_widget, w}) end,
      set_footer: fn f -> cast.({:set_footer, f}) end,
      set_header: fn h -> cast.({:set_header, h}) end,
      set_title: fn t -> cast.({:set_title, t}) end,
      set_editor_component: fn c -> cast.({:set_editor_component, c}) end,
      add_autocomplete_provider: fn p -> cast.({:add_autocomplete_provider, p}) end,
      select: fn opts, kw ->
        GenServer.call(pid, {:ui_request, {:select, opts, kw}}, :infinity)
      end,
      confirm: fn prompt, kw ->
        GenServer.call(pid, {:ui_request, {:confirm, prompt, kw}}, :infinity)
      end,
      input: fn prompt, kw ->
        GenServer.call(pid, {:ui_request, {:input, prompt, kw}}, :infinity)
      end,
      editor: fn content, kw ->
        GenServer.call(pid, {:ui_request, {:editor, content, kw}}, :infinity)
      end,
      custom: fn term, kw ->
        GenServer.call(pid, {:ui_request, {:custom, term, kw}}, :infinity)
      end
    })
  end
end
