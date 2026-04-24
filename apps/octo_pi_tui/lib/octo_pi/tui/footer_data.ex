defmodule OctoPi.TUI.FooterData do
  @moduledoc """
  Supplies live data to the footer: git branch and extension statuses.
  Reads `.git/HEAD` on startup and re-reads on a GenServer timeout.
  """

  use GenServer

  @poll_interval_ms 5_000

  @type t :: %{
          cwd: String.t(),
          git_branch: String.t() | nil,
          extension_statuses: %{String.t() => String.t()}
        }

  # --- public API ---

  def start_link(opts) do
    {cwd, opts} = Keyword.pop!(opts, :cwd)
    GenServer.start_link(__MODULE__, cwd, opts)
  end

  @spec get_git_branch(GenServer.server()) :: String.t() | nil
  def get_git_branch(pid), do: GenServer.call(pid, :get_git_branch)

  @spec get_extension_statuses(GenServer.server()) :: %{String.t() => String.t()}
  def get_extension_statuses(pid), do: GenServer.call(pid, :get_extension_statuses)

  @spec set_extension_status(GenServer.server(), String.t(), String.t()) :: :ok
  def set_extension_status(pid, key, text), do: GenServer.cast(pid, {:set_ext, key, text})

  @spec clear_extension_status(GenServer.server(), String.t()) :: :ok
  def clear_extension_status(pid, key), do: GenServer.cast(pid, {:clear_ext, key})

  # --- GenServer callbacks ---

  @impl true
  def init(cwd) do
    state = %{cwd: cwd, git_branch: read_git_branch(cwd), extension_statuses: %{}}
    {:ok, state, @poll_interval_ms}
  end

  @impl true
  def handle_call(:get_git_branch, _from, state),
    do: {:reply, state.git_branch, state, @poll_interval_ms}

  def handle_call(:get_extension_statuses, _from, state),
    do: {:reply, state.extension_statuses, state, @poll_interval_ms}

  @impl true
  def handle_cast({:set_ext, key, text}, state),
    do: {:noreply, put_in(state, [:extension_statuses, key], text), @poll_interval_ms}

  def handle_cast({:clear_ext, key}, state),
    do: {:noreply, %{state | extension_statuses: Map.delete(state.extension_statuses, key)}, @poll_interval_ms}

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, %{state | git_branch: read_git_branch(state.cwd)}, @poll_interval_ms}
  end

  # --- git branch detection ---

  defp read_git_branch(cwd) do
    head_path = Path.join([cwd, ".git", "HEAD"])

    case File.read(head_path) do
      {:ok, content} -> parse_head(String.trim(content))
      {:error, _} -> nil
    end
  end

  defp parse_head("ref: refs/heads/" <> branch), do: branch

  defp parse_head(sha) when byte_size(sha) >= 7 do
    String.slice(sha, 0, 7)
  end

  defp parse_head(_), do: nil
end
