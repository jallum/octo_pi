defmodule OctoPi.Coder.SessionStore do
  @moduledoc """
  Per-session JSONL writer. Opens a file at

      <root>/sessions/--<encoded-cwd>--/<timestamp>_<id>.jsonl

  writes a v3 `SessionHeader` as the first line, then appends typed
  entries via `append/2`. One GenServer per session id, supervised
  under `OctoPi.Coder.SessionStore.Supervisor`.

  File handle stays open for the lifetime of the store to avoid
  re-opening on every append. `close/1` flushes and terminates
  the GenServer cleanly — it is *terminal*, subsequent calls to
  the same pid will fail with `:noproc`.

  ## Byte-compatibility with upstream `pi`

  The emitted JSON preserves key insertion order so header lines
  match upstream v3 byte-for-byte. Entries passed to `append/2`
  are encoded with their given key order (callers that care about
  cross-tool readability should pass a keyword list).

  The cwd-encoding scheme (`/` → `-`) is lossy: `/a/b` and `/a-b`
  both encode to `a-b` and would share the same session directory.
  This matches upstream pi exactly — changing it would break
  cross-tool session sharing.

  ## Filename format

  New sessions: `{iso8601-timestamp}_{id}.jsonl` with `:` and `.`
  replaced by `-`, matching upstream pi-mono exactly.

  Resumed sessions: pass `:path` explicitly. The file is opened in
  append mode and no header is written.
  """

  use GenServer, restart: :temporary

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header

  @type open_opt ::
          {:id, String.t()}
          | {:cwd, String.t()}
          | {:root, String.t()}
          | {:parent_session, String.t() | nil}
          | {:path, String.t()}

  @default_root Path.expand("~/.pi/agent")

  @doc """
  Start a session store and write its header. Opts:

    * `:id` (required) — session id (typically a UUID)
    * `:cwd` (required) — absolute working directory
    * `:root` — base dir (default `~/.pi/agent`)
    * `:parent_session` — optional parent session id
    * `:path` — use this exact path instead of computing one; opens in
      append mode without writing a header (for resumption)
  """
  @spec open([open_opt()]) :: {:ok, pid()}
  def open(opts) do
    DynamicSupervisor.start_child(
      OctoPi.Coder.SessionStore.Supervisor,
      {__MODULE__, opts}
    )
  end

  @doc "Full path to the session file."
  @spec path(pid()) :: String.t()
  def path(pid), do: GenServer.call(pid, :path)

  @doc "Append a typed entry as a JSON line."
  @spec append(pid(), map() | keyword()) :: :ok
  def append(pid, entry), do: GenServer.call(pid, {:append, entry})

  @doc "Flush and shut down."
  @spec close(pid()) :: :ok
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

  Returns a lazy `Stream` that yields one entry per non-empty line:
  the first element is an `OctoPi.Coder.Session.Header.t()`, followed by
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
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    case Keyword.get(opts, :path) do
      nil ->
        cwd = Keyword.fetch!(opts, :cwd)
        root = Keyword.get(opts, :root, @default_root)
        parent = Keyword.get(opts, :parent_session)

        path = build_path(root, cwd, id)
        File.mkdir_p!(Path.dirname(path))
        io = File.open!(path, [:write, :utf8])
        write_header(io, id, cwd, parent)
        {:ok, %{id: id, path: path, io: io}}

      existing_path ->
        File.mkdir_p!(Path.dirname(existing_path))
        io = File.open!(existing_path, [:append, :utf8])
        {:ok, %{id: id, path: existing_path, io: io}}
    end
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:append, entry}, _from, state) do
    IO.write(state.io, encode_line(entry))
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    File.close(state.io)
    {:stop, :normal, :ok, state}
  end

  # -- helpers --

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

  defp write_header(io, id, cwd, parent) do
    header = [
      {"type", "session"},
      {"version", 3},
      {"id", id},
      {"timestamp", iso8601_now()},
      {"cwd", cwd},
      {"parentSession", parent}
    ]

    IO.write(io, encode_line(header))
  end

  # Keyword-list-shaped input (string or atom key, value) emits as a
  # JSON object with keys in list order via `Jason.OrderedObject` —
  # byte-compat with upstream. Map-shaped input goes through Jason's
  # normal encoder which is hash-ordered; callers that care about key
  # order should pass an ordered list of pairs.
  defp encode_line(entry) when is_list(entry) do
    normalized = Enum.map(entry, fn {k, v} -> {to_string(k), v} end)
    Jason.encode!(Jason.OrderedObject.new(normalized)) <> "\n"
  end

  defp encode_line(entry) when is_map(entry), do: Jason.encode!(entry) <> "\n"

  defp iso8601_now, do: DateTime.to_iso8601(DateTime.utc_now())
end
