defmodule OctoPi.Coder.SessionStore do
  @moduledoc """
  Per-session JSONL writer **and** tree-of-record. Owns the in-memory
  `SessionManager` struct (by_id, file_entries, leaf_id, label index)
  and an open file handle. One GenServer per session id, supervised
  under `OctoPi.Coder.SessionStore.Supervisor`.

  ## Two start modes

    * **New session** — pass `:id` + `:cwd` (+ optional `:root`,
      `:parent_session`). The file is created at
      `<root>/sessions/--<encoded-cwd>--/<timestamp>_<id>.jsonl` and the
      v3 `SessionHeader` is written eagerly as line 1.
    * **Resume** — pass `:path` (an existing JSONL file). The file is
      loaded via `SessionManager.load/1`, migrations applied if needed,
      and the file opened in append mode without writing a header. `:id`
      is derived from the loaded header.

  ## Public surface

  Two layers of mutation:

    * `append/2` — low-level append of a raw map / keyword pair list as
      a JSONL line. Writes the bytes verbatim. The store does **not**
      update its internal SessionManager from this call. Used by tests
      and tooling that already control id/parent linking.
    * `append_entry/3` — typed-entry append. Mints id, links parent to
      current leaf, fills timestamp, persists, and updates the in-memory
      tree. Returns the materialized `%Entry{...}` struct (with id /
      parent_id / timestamp filled in) so callers can update their own
      view of the path without re-querying.

  Reads are GenServer.calls that delegate to `SessionManager` pure
  functions on the in-memory struct: `get_entry/2`, `get_entries/1`,
  `get_branch/1,2`, `get_leaf_entry_id/1`, `find_common_ancestor/3`,
  `collect_entries_for_branch_summary/3`, `build_session_context/1,2`.

  File handle stays open for the lifetime of the store. `close/1` is
  *terminal*; subsequent calls will fail with `:noproc`.

  ## Byte-compatibility with upstream `pi`

  The emitted JSON preserves key insertion order so header lines and
  typed entries match upstream v3 byte-for-byte. The cwd-encoding scheme
  (`/` → `-`) is lossy and intentionally matches upstream pi exactly —
  changing it would break cross-tool session sharing.
  """

  use GenServer, restart: :temporary

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header
  alias OctoPi.Coder.SessionManager

  @opaque t :: pid()

  @type open_opt ::
          {:id, String.t()}
          | {:cwd, String.t()}
          | {:root, String.t()}
          | {:parent_session, String.t() | nil}
          | {:path, String.t()}

  @default_root Path.expand("~/.pi/agent")

  @doc """
  Start a session store. See module doc for the two start modes.
  """
  @spec open([open_opt()]) :: {:ok, t()}
  def open(opts) do
    DynamicSupervisor.start_child(
      OctoPi.Coder.SessionStore.Supervisor,
      {__MODULE__, opts}
    )
  end

  @doc "Full path to the session file."
  @spec path(t()) :: String.t()
  def path(pid), do: GenServer.call(pid, :path)

  @doc """
  Append a raw JSON line — escape hatch that does NOT update the
  in-memory tree. Prefer `append_entry/3`.
  """
  @spec append(t(), map() | keyword()) :: :ok
  def append(pid, entry), do: GenServer.call(pid, {:append, entry})

  @doc """
  Append a typed `%Entry{}` to the session: mints id, links parent to
  current leaf, fills timestamp, persists, and updates the in-memory
  tree. Returns the materialized entry with id / parent_id / timestamp
  filled in.

  Options:

    * `:id` — explicit id (skips generation; collision still checked)
    * `:timestamp` — explicit ISO-8601 timestamp (defaults to now)
  """
  @spec append_entry(t(), Entry.t(), keyword()) :: {:ok, Entry.t()}
  def append_entry(pid, entry, opts \\ []), do: GenServer.call(pid, {:append_entry, entry, opts})

  @doc "Look up an entry by id. Returns `nil` if not found."
  @spec get_entry(t(), String.t()) :: Entry.t() | nil
  def get_entry(pid, id), do: GenServer.call(pid, {:get_entry, id})

  @doc "All body entries (header excluded), in file order."
  @spec get_entries(t()) :: [Entry.t()]
  def get_entries(pid), do: GenServer.call(pid, :get_entries)

  @doc "Walk from current leaf to root; returns root→leaf order. `[]` for empty session."
  @spec get_branch(t()) :: [Entry.t()]
  def get_branch(pid), do: GenServer.call(pid, :get_branch)

  @doc "Walk from given entry id to root; returns root→leaf order."
  @spec get_branch(t(), String.t()) :: [Entry.t()]
  def get_branch(pid, from_id), do: GenServer.call(pid, {:get_branch, from_id})

  @doc """
  Single read primitive — walk from a leaf toward root with an optional
  stop anchor. See `OctoPi.Coder.SessionManager.path/3` for full
  semantics.

  ## Arguments

    * `leaf` — `:leaf` (current leaf), an entry id, or `nil` (returns `[]`).
    * `opts[:to]` — `:root` (default), `:latest_compaction`, or a binary id.

  Note: the file-path getter is the no-arg `path/1`; this read primitive
  is `path/3` (no default args) to avoid shadowing it.
  """
  @spec path(t(), :leaf | String.t() | nil, keyword()) :: [Entry.t()]
  def path(pid, leaf, opts), do: GenServer.call(pid, {:path, leaf, opts})

  @doc "Id of the current leaf entry, or `nil` for an empty session."
  @spec get_leaf_entry_id(t()) :: String.t() | nil
  def get_leaf_entry_id(pid), do: GenServer.call(pid, :get_leaf_entry_id)

  @doc """
  Deepest entry id on both paths (`old_leaf_id`→root and `target_id`→root).
  Returns `nil` when there is no shared ancestor or when `old_leaf_id` is `nil`.
  """
  @spec find_common_ancestor(t(), String.t() | nil, String.t()) :: String.t() | nil
  def find_common_ancestor(pid, old_leaf_id, target_id),
    do: GenServer.call(pid, {:find_common_ancestor, old_leaf_id, target_id})

  @doc """
  Entries to summarize when navigating from `old_leaf_id` to `target_id`,
  in chronological order, plus the common ancestor id.
  """
  @spec collect_entries_for_branch_summary(t(), String.t() | nil, String.t()) ::
          {[Entry.t()], String.t() | nil}
  def collect_entries_for_branch_summary(pid, old_leaf_id, target_id),
    do: GenServer.call(pid, {:collect_entries_for_branch_summary, old_leaf_id, target_id})

  @doc """
  Build the LLM-ready session context from the current branch. Equivalent to
  `SessionManager.build_session_context/2` but executed inside the store
  process so it sees the latest state.
  """
  @spec build_session_context(t()) ::
          %{messages: [term()], thinking_level: String.t(), model: map() | nil}
  def build_session_context(pid), do: GenServer.call(pid, {:build_session_context, :default})

  @spec build_session_context(t(), String.t() | nil) ::
          %{messages: [term()], thinking_level: String.t(), model: map() | nil}
  def build_session_context(pid, leaf_id), do: GenServer.call(pid, {:build_session_context, leaf_id})

  @doc "Session id (stable for the lifetime of this store)."
  @spec get_session_id(t()) :: String.t()
  def get_session_id(pid), do: GenServer.call(pid, :get_session_id)

  @doc "Working directory recorded in the session header."
  @spec get_cwd(t()) :: String.t()
  def get_cwd(pid), do: GenServer.call(pid, :get_cwd)

  @doc """
  Snapshot of the in-memory `SessionManager` struct. Provided to ease
  the transition from a Loop-owned struct to a store-owned one; new code
  should prefer the typed read API (`get_branch/1`, `get_entry/2`, …).
  """
  @spec get_session_manager(t()) :: SessionManager.t()
  def get_session_manager(pid), do: GenServer.call(pid, :get_session_manager)

  @doc """
  Move the leaf pointer to `leaf_id` without appending an entry. Used
  by branch navigation — the next `append_entry/3` call will create a
  child of `leaf_id`.
  """
  @spec set_leaf(t(), String.t() | nil) :: :ok
  def set_leaf(pid, leaf_id), do: GenServer.call(pid, {:set_leaf, leaf_id})

  @doc "Flush and shut down."
  @spec close(t()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  @doc """
  Compute the session directory for a given cwd.

      SessionStore.session_dir(cwd)
      #=> "~/.pi/agent/sessions/--home-alice-proj--"
  """
  @spec session_dir(String.t(), String.t()) :: String.t()
  def session_dir(cwd, root \\ @default_root) do
    Path.join([root, "sessions", "--" <> encode_cwd(cwd) <> "--"])
  end

  @doc """
  Stream a session JSONL file as decoded entries (header + body).

  Returns a lazy `Stream` that yields one entry per non-empty line: the
  first element is an `OctoPi.Coder.Session.Header.t()`, followed by
  values from the `OctoPi.Coder.Session.Entry` union. Malformed JSON
  lines are silently skipped (mirrors upstream `parseSessionEntries`,
  `tmp/pi-mono/.../session-manager.ts:284-299`).
  """
  @spec read_entries(Path.t()) :: Enumerable.t()
  def read_entries(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&is_nil/1)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "session"} = m} -> Header.decode(m)
      {:ok, %{"type" => _} = m} -> Entry.decode(m)
      _ -> nil
    end
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: do_init(Keyword.get(opts, :path), opts)

  defp do_init(nil, opts) do
    id = Keyword.fetch!(opts, :id)
    cwd = Keyword.fetch!(opts, :cwd)
    root = Keyword.get(opts, :root, @default_root)
    parent = Keyword.get(opts, :parent_session)

    path = build_path(root, cwd, id)
    File.mkdir_p!(Path.dirname(path))
    io = File.open!(path, [:write, :utf8])
    timestamp = iso8601_now()
    header = build_header(id, cwd, parent, timestamp)
    IO.write(io, encode_line(Header.pairs(header)))

    sm = %SessionManager{
      cwd: cwd,
      session_id: id,
      session_file: path,
      parent_session: parent,
      version: 3,
      file_entries: [header],
      by_id: %{},
      leaf_id: nil,
      migrated?: false
    }

    {:ok, %{path: path, io: io, sm: sm}}
  end

  defp do_init(existing_path, _opts) do
    File.mkdir_p!(Path.dirname(existing_path))

    case SessionManager.load(existing_path) do
      {:ok, sm} ->
        io = File.open!(existing_path, [:append, :utf8])
        {:ok, %{path: existing_path, io: io, sm: sm}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call(:get_session_id, _from, state), do: {:reply, state.sm.session_id, state}

  def handle_call(:get_cwd, _from, state), do: {:reply, state.sm.cwd, state}

  def handle_call(:get_session_manager, _from, state), do: {:reply, state.sm, state}

  def handle_call(:get_entries, _from, state), do: {:reply, SessionManager.get_entries(state.sm), state}

  def handle_call({:get_entry, id}, _from, state), do: {:reply, SessionManager.get_entry(state.sm, id), state}

  def handle_call(:get_branch, _from, state), do: {:reply, SessionManager.get_branch(state.sm), state}

  def handle_call({:get_branch, from_id}, _from, state),
    do: {:reply, SessionManager.get_branch(state.sm, from_id), state}

  def handle_call({:path, leaf, opts}, _from, state), do: {:reply, SessionManager.path(state.sm, leaf, opts), state}

  def handle_call(:get_leaf_entry_id, _from, state), do: {:reply, SessionManager.get_leaf_entry_id(state.sm), state}

  def handle_call({:find_common_ancestor, old_leaf_id, target_id}, _from, state),
    do: {:reply, SessionManager.find_common_ancestor(state.sm, old_leaf_id, target_id), state}

  def handle_call({:collect_entries_for_branch_summary, old_leaf_id, target_id}, _from, state),
    do: {:reply, SessionManager.collect_entries_for_branch_summary(state.sm, old_leaf_id, target_id), state}

  def handle_call({:build_session_context, :default}, _from, state),
    do: {:reply, SessionManager.build_session_context(state.sm), state}

  def handle_call({:build_session_context, leaf_id}, _from, state),
    do: {:reply, SessionManager.build_session_context(state.sm, leaf_id), state}

  def handle_call({:append, entry}, _from, state) do
    IO.write(state.io, encode_line(entry))
    {:reply, :ok, state}
  end

  def handle_call({:append_entry, entry, opts}, _from, state) do
    {sm, materialized} = SessionManager.add_entry(state.sm, entry, opts)
    IO.write(state.io, encode_line(Entry.pairs(materialized)))
    {:reply, {:ok, materialized}, %{state | sm: sm}}
  end

  def handle_call({:set_leaf, leaf_id}, _from, state),
    do: {:reply, :ok, %{state | sm: SessionManager.set_leaf(state.sm, leaf_id)}}

  def handle_call(:close, _from, state) do
    File.close(state.io)
    {:stop, :normal, :ok, state}
  end

  # -- helpers --

  defp build_header(id, cwd, parent, timestamp) do
    %Header{id: id, version: 3, timestamp: timestamp, cwd: cwd, parent_session: parent}
  end

  defp build_path(root, cwd, id) do
    encoded = encode_cwd(cwd)
    ts = timestamp_prefix()
    Path.join([root, "sessions", "--" <> encoded <> "--", ts <> "_" <> id <> ".jsonl"])
  end

  # Upstream encodes absolute paths by replacing `/` with `-`.
  # `/home/alice/proj` → `home-alice-proj`.
  defp encode_cwd("/" <> rest), do: String.replace(rest, "/", "-")
  defp encode_cwd(cwd), do: String.replace(cwd, "/", "-")

  # Upstream filename timestamp: ISO 8601 with `:` and `.` replaced by `-`.
  # e.g. `2026-04-28T01-58-51-657Z`
  defp timestamp_prefix do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(":", "-")
    |> String.replace(".", "-")
  end

  # Keyword-list-shaped input (string or atom key, value) emits as a
  # JSON object with keys in list order via `Jason.OrderedObject` —
  # byte-compat with upstream. Map-shaped input goes through Jason's
  # normal encoder which is hash-ordered; callers that care about key
  # order should pass an ordered list of pairs.
  defp encode_line(entry) when is_list(entry) do
    normalized = Enum.map(entry, fn {k, v} -> {to_string(k), scrub_utf8(v)} end)
    Jason.encode!(Jason.OrderedObject.new(normalized)) <> "\n"
  end

  defp encode_line(entry) when is_map(entry), do: Jason.encode!(scrub_utf8(entry)) <> "\n"

  defp scrub_utf8(v) when is_binary(v) do
    case :unicode.characters_to_binary(v) do
      s when is_binary(s) -> s
      {:error, good, _} -> good
      {:incomplete, good, _} -> good
    end
  end

  defp scrub_utf8(v) when is_list(v), do: Enum.map(v, &scrub_utf8/1)
  defp scrub_utf8(%{} = v), do: Map.new(v, fn {k, val} -> {scrub_utf8(k), scrub_utf8(val)} end)
  defp scrub_utf8(v), do: v

  defp iso8601_now, do: DateTime.to_iso8601(DateTime.utc_now())
end
