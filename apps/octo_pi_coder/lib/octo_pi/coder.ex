defmodule OctoPi.Coder do
  @moduledoc """
  Coding-agent core: the application layer that composes the
  `OctoPi.Agent` kernel with a JSONL session store, built-in file +
  bash + search tools, and the Print output mode.

  Entry points:

      OctoPi.Coder.start_loop(opts)         # start a coder loop GenServer
      OctoPi.Coder.start_loop_supervised(opts)
      OctoPi.Coder.run_print(opts)             # non-interactive single-shot run
      OctoPi.Coder.default_tools(cwd)
  """

  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Loop
  alias OctoPi.Coder.Modes.Print
  alias OctoPi.Coder.ResourceLoader
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.Tools

  @opaque t :: pid()

  @type print_opts :: [
          prompt: String.t(),
          model: Model.t(),
          cwd: String.t(),
          tools: [Tool.t()],
          transport: module(),
          system_prompt: String.t() | nil,
          resource_loader: ResourceLoader.t()
        ]

  @type compact_result :: Loop.compact_result()
  @type fork_result :: Loop.fork_result()
  @type navigate_tree_result :: Loop.navigate_tree_result()

  # ---- Loop lifecycle ----

  @doc """
  Start a loop GenServer.
  Required: `:extensions`, `:session_manager`, `:store_pid`.
  """
  @spec start_loop(Loop.start_opts()) :: {:ok, t()} | :ignore | {:error, term()}
  def start_loop(opts), do: Loop.start_link(opts)

  @doc "Start a loop under `OctoPi.Coder.Loop.Supervisor` (DynamicSupervisor)."
  @spec start_loop_supervised(Loop.start_opts()) :: {:ok, t()} | :ignore | {:error, term()}
  def start_loop_supervised(opts), do: Loop.start_supervised(opts)

  # ---- Agent interaction ----

  @doc """
  Subscribe `subscriber` to agent events. The caller will receive
  `{:octo_pi_agent_event, event}` messages.
  """
  @spec subscribe(t(), pid(), :async | :sync) :: :ok
  def subscribe(server, subscriber, mode \\ :async), do: GenServer.call(server, {:agent_subscribe, subscriber, mode})

  @doc """
  Write the user message entry to the session file and dispatch the prompt
  to the agent. `save_text` is persisted as-is; `send_text` is what the
  agent receives (allows template expansion by the caller). When `send_text`
  is omitted it defaults to `save_text`.
  """
  @spec prompt(t(), String.t()) :: :ok | {:error, term()}
  def prompt(server, save_text), do: prompt(server, save_text, save_text)

  @spec prompt(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def prompt(server, save_text, send_text), do: GenServer.call(server, {:agent_prompt, save_text, send_text})

  @doc "Abort the current agent run."
  @spec abort(t()) :: :ok
  def abort(server), do: GenServer.call(server, :agent_abort)

  @doc "Queue a follow-up message with the held agent."
  @spec follow_up(t(), String.t()) :: :ok
  def follow_up(server, text), do: GenServer.call(server, {:agent_follow_up, text})

  @doc "Queue a steering message with the held agent."
  @spec steer(t(), String.t()) :: :ok
  def steer(server, text), do: GenServer.call(server, {:agent_steer, text})

  @doc "Change the model for future runs."
  @spec set_model(t(), Model.t()) :: :ok
  def set_model(server, model), do: GenServer.call(server, {:agent_set_model, model})

  @doc "Change the thinking level for future runs."
  @spec set_thinking_level(t(), atom()) :: :ok
  def set_thinking_level(server, level), do: GenServer.call(server, {:agent_set_thinking_level, level})

  @doc "Register an additional tool with the held agent."
  @spec add_tool(t(), Tool.t()) :: :ok
  def add_tool(server, tool), do: GenServer.call(server, {:agent_add_tool, tool})

  @doc "Drain and return pending steering messages from the agent queue."
  @spec drain_steering(t()) :: [String.t()]
  def drain_steering(server), do: GenServer.call(server, :agent_drain_steering)

  @doc "Drain and return pending follow-up messages from the agent queue."
  @spec drain_follow_up(t()) :: [String.t()]
  def drain_follow_up(server), do: GenServer.call(server, :agent_drain_follow_up)

  # ---- Session management ----

  @doc "Wire an agent into the loop after init."
  @spec set_agent_pid(t(), OctoPi.Agent.t()) :: :ok
  def set_agent_pid(server, agent_pid), do: GenServer.call(server, {:set_agent_pid, agent_pid})

  @doc """
  Build the LLM-ready session context from the held `SessionManager`'s
  current branch.
  """
  @spec build_session_context(t()) :: %{messages: [term()], thinking_level: String.t(), model: map() | nil}
  def build_session_context(server), do: GenServer.call(server, :build_session_context)

  @doc "Return the current `SessionManager`."
  @spec get_session_manager(t()) :: SessionManager.t()
  def get_session_manager(server), do: GenServer.call(server, :get_session_manager)

  @doc "Return the loaded extension list."
  @spec get_extensions(t()) :: [Extension.t()]
  def get_extensions(server), do: GenServer.call(server, :get_extensions)

  @doc "Append an entry to the session."
  @spec add_entry(t(), Entry.t(), keyword()) :: {:ok, String.t()}
  def add_entry(server, entry, opts \\ []), do: GenServer.call(server, {:add_entry, entry, opts})

  @doc "Append a user prompt to the session."
  @spec add_user_message(t(), User.t()) :: {:ok, String.t()}
  def add_user_message(server, %User{} = msg), do: GenServer.call(server, {:add_user_message, msg})

  # ---- Session operations ----

  @doc "Run the compaction orchestrator."
  @spec compact(t(), keyword()) :: compact_result()
  def compact(server, opts \\ []), do: GenServer.call(server, {:compact, opts}, :infinity)

  @doc "Fork the current session into a new session file."
  @spec fork(t(), keyword()) :: fork_result()
  def fork(server, opts), do: GenServer.call(server, {:fork, opts}, :infinity)

  @doc "Navigate the session tree to a target entry."
  @spec navigate_tree(t(), keyword()) :: navigate_tree_result()
  def navigate_tree(server, opts), do: GenServer.call(server, {:navigate_tree, opts}, :infinity)

  # ---- Queries ----

  @doc "Estimate context token usage for the current session."
  @spec get_context_usage(t()) :: map() | nil
  def get_context_usage(server), do: GenServer.call(server, :get_context_usage)

  @doc "Session statistics: running token totals and context usage."
  @spec get_session_stats(t()) :: map()
  def get_session_stats(server), do: GenServer.call(server, :get_session_stats)

  @doc "Return the current compaction settings."
  @spec get_compaction_settings(t()) :: Settings.t()
  def get_compaction_settings(server), do: GenServer.call(server, :get_compaction_settings)

  @doc "Return all entries from the session's `SessionManager`."
  @spec get_entries(t()) :: [Entry.t()]
  def get_entries(server), do: GenServer.call(server, :get_entries)

  # ---- Print mode ----

  @doc """
  Non-interactive single-shot run. Streams text and tool-event markers
  to stdout, returns the stop reason.

  Required: `:prompt`, `:model`. Returns `{:ok, reason}` for a clean
  stop or `{:error, reason}` for `:error`/`:aborted`.
  """
  @spec run_print(print_opts()) :: {:ok, atom()} | {:error, atom()}
  def run_print(opts) when is_list(opts), do: Print.run(opts)

  # ---- Tools ----

  @doc """
  The seven built-in tools (read/write/edit/ls/bash/grep/find),
  each rooted at `cwd`.
  Used by Print mode and the TUI's Interactive mode so they present
  an identical tool surface to the agent.
  """
  @spec default_tools(String.t()) :: [Tool.t()]
  def default_tools(cwd) when is_binary(cwd) do
    [
      Tools.Read.tool(cwd),
      Tools.Write.tool(cwd),
      Tools.Edit.tool(cwd),
      Tools.Ls.tool(cwd),
      Tools.Bash.tool(cwd),
      Tools.Grep.tool(cwd),
      Tools.Find.tool(cwd)
    ]
  end
end
