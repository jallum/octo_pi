defmodule OctoPi.Coder.Extension.ToolRender do
  @moduledoc false

  @type render_context :: %__MODULE__.Context{
          args: map(),
          tool_call_id: String.t(),
          cwd: String.t(),
          execution_started: boolean(),
          args_complete: boolean(),
          is_partial: boolean(),
          expanded: boolean(),
          show_images: boolean(),
          is_error: boolean(),
          state: term(),
          invalidate: (-> :ok),
          last_component: term()
        }

  defmodule Context do
    @moduledoc false

    defstruct args: %{},
              tool_call_id: nil,
              cwd: ".",
              execution_started: false,
              args_complete: false,
              is_partial: false,
              expanded: false,
              show_images: false,
              is_error: false,
              state: nil,
              invalidate: nil,
              last_component: nil
  end

  @type render_fn :: (Context.t() -> term())

  @type tool_render_opts :: %{
          optional(:render_call) => render_fn(),
          optional(:render_result) => render_fn(),
          optional(:render_shell) => :default | :self,
          optional(:prepare_arguments) => (map() -> map()),
          optional(:execution_mode) => :sequential | :parallel,
          optional(:prompt_snippet) => String.t(),
          optional(:prompt_guidelines) => [String.t()]
        }

  @spec merge_into_tool(map(), tool_render_opts()) :: map()
  def merge_into_tool(tool, opts) when is_map(tool) and is_map(opts) do
    Map.merge(tool, Map.take(opts, [
      :render_call, :render_result, :render_shell,
      :prepare_arguments, :execution_mode,
      :prompt_snippet, :prompt_guidelines
    ]))
  end
end
