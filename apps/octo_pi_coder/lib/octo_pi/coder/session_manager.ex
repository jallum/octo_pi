defmodule OctoPi.Coder.SessionManager do
  @moduledoc """
  In-memory tree model for a session JSONL file. Mirrors the
  `SessionManager` class in `tmp/pi-mono/.../core/session-manager.ts:669`
  for the load + tree-reconstruction surface; mutation surfaces
  (append, fork, branch, build_session_context) land in later
  Phase B/C/E tickets.

  Each session entry has an `id` and a `parent_id` forming a tree.
  The file is a linear projection of one branch path; the in-memory
  byId index lets later tickets reconstruct branches and walk
  ancestor chains.

  This ticket (B1) provides `load/1`: read JSONL → migrate to v3 →
  build the byId index → set the leaf to the last appended body
  entry. Pi-mono migrations applied during load:

    * v1 → v2 — assign collision-checked 8-hex `id` to every body
      entry; chain `parent_id` to the previous entry's id; convert
      compaction `firstKeptEntryIndex` (positional) to
      `firstKeptEntryId` (id-based). Mirrors `migrateV1ToV2`
      (`session-manager.ts:216-242`).
    * v2 → v3 — rename Message message-role `"hookMessage"` to
      `"custom"`. Mirrors `migrateV2ToV3` (`session-manager.ts:245-260`).
  """

  alias OctoPi.Coder.Session.BranchSummaryMessage
  alias OctoPi.Coder.Session.CompactionSummaryMessage
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header
  alias OctoPi.Coder.SessionStore

  @current_version 3

  @enforce_keys [:cwd, :session_id]
  defstruct [
    :cwd,
    :session_id,
    :session_file,
    :parent_session,
    :version,
    file_entries: [],
    by_id: %{},
    leaf_id: nil,
    migrated?: false
  ]

  @type entry :: Entry.t()
  @type t :: %__MODULE__{
          cwd: String.t(),
          session_id: String.t(),
          session_file: Path.t() | nil,
          parent_session: String.t() | nil,
          version: integer(),
          file_entries: [Header.t() | entry()],
          by_id: %{optional(String.t()) => entry()},
          leaf_id: String.t() | nil,
          migrated?: boolean()
        }

  @doc """
  Load a session file. Returns the reconstructed in-memory tree.

  Errors:
    * `{:error, :enoent}` — file does not exist
    * `{:error, :empty}` — file has no parseable lines
    * `{:error, :missing_header}` — first parseable entry is not a header
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, :enoent | :empty | :missing_header}
  def load(path) do
    if File.exists?(path) do
      path |> SessionStore.read_entries() |> Enum.to_list() |> from_entries(path)
    else
      {:error, :enoent}
    end
  end

  defp from_entries([], _path), do: {:error, :empty}

  defp from_entries([%Header{} = header | body], path) do
    source_version = header.version || 1
    body_v2 = ensure_ids(body, source_version)
    body_v3 = ensure_v3_roles(body_v2, source_version)
    {by_id, leaf_id} = index(body_v3)
    migrated? = source_version < @current_version
    final_version = if migrated?, do: @current_version, else: source_version
    final_header = %{header | version: final_version}

    {:ok,
     %__MODULE__{
       cwd: header.cwd,
       session_id: header.id,
       session_file: path,
       parent_session: header.parent_session,
       version: final_version,
       file_entries: [final_header | body_v3],
       by_id: by_id,
       leaf_id: leaf_id,
       migrated?: migrated?
     }}
  end

  defp from_entries(_, _path), do: {:error, :missing_header}

  # ------- traversal -------

  @doc """
  All body entries (header excluded) in file order. Mirrors
  `getEntries()` (`session-manager.ts:1066-1068`).
  """
  @spec get_entries(t()) :: [entry()]
  def get_entries(%__MODULE__{file_entries: entries}) do
    Enum.reject(entries, &match?(%Header{}, &1))
  end

  @doc """
  The id of the current leaf entry, or `nil` for an empty session.
  Mirrors `getLeafId()` (`session-manager.ts:969`). The extension API
  field is named `get_leaf_entry_id`.
  """
  @spec get_leaf_entry_id(t()) :: String.t() | nil
  def get_leaf_entry_id(%__MODULE__{leaf_id: id}), do: id

  @doc """
  Walk from the current leaf to root and return the path in
  root→leaf order. Returns `[]` when the session has no leaf.
  Mirrors `getBranch()` with no argument (`session-manager.ts:1034`).
  """
  @spec get_branch(t()) :: [entry()]
  def get_branch(%__MODULE__{leaf_id: nil}), do: []
  def get_branch(%__MODULE__{leaf_id: id} = sm), do: get_branch(sm, id)

  @doc """
  Walk from the given entry id to root and return the path in
  root→leaf order. Returns `[]` if the id is unknown. Orphaned
  ancestors (parent_id pointing to a missing entry) terminate the
  walk early so the returned path is always a contiguous chain
  ending at the requested entry. Mirrors `getBranch(fromId)`
  (`session-manager.ts:1034-1043`).
  """
  @spec get_branch(t(), String.t()) :: [entry()]
  def get_branch(%__MODULE__{by_id: by_id}, from_id) when is_binary(from_id) do
    walk_to_root(by_id, Map.get(by_id, from_id), [])
  end

  defp walk_to_root(_by_id, nil, acc), do: acc

  defp walk_to_root(by_id, entry, acc) do
    parent_id = entry_parent(entry)
    parent = parent_id && Map.get(by_id, parent_id)
    walk_to_root(by_id, parent, [entry | acc])
  end

  defp entry_parent(%Entry.Passthrough{raw: r}), do: r["parentId"]
  defp entry_parent(entry), do: Map.get(entry, :parent_id)

  @doc """
  Find the deepest entry id that lies on both `from old_leaf_id to root`
  and `from target_id to root`. Returns `nil` when there is no shared
  ancestor (e.g. either id is unknown, `old_leaf_id` is `nil`, or the
  paths are disjoint).

  Mirrors the common-ancestor scan in
  `tmp/pi-mono/.../compaction/branch-summarization.ts:108-119`.
  """
  @spec find_common_ancestor(t(), String.t() | nil, String.t()) :: String.t() | nil
  def find_common_ancestor(_sm, nil, _target_id), do: nil

  def find_common_ancestor(%__MODULE__{} = sm, old_leaf_id, target_id)
      when is_binary(old_leaf_id) and is_binary(target_id) do
    old_ids = sm |> get_branch(old_leaf_id) |> Enum.map(&entry_id/1) |> MapSet.new()

    sm
    |> get_branch(target_id)
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      id = entry_id(entry)
      if MapSet.member?(old_ids, id), do: id
    end)
  end

  @doc """
  Collect entries that should be summarized when navigating from one
  tree position to another. Walks from `old_leaf_id` back to the common
  ancestor with `target_id`, **not** stopping at compaction boundaries
  (compaction entries are included so their summaries provide context).

  Returns `{entries_in_chronological_order, common_ancestor_id}`.
  When `old_leaf_id` is `nil` there is nothing to summarize: `{[], nil}`.

  Port of `collectEntriesForBranchSummary`
  (`tmp/pi-mono/.../compaction/branch-summarization.ts:98-136`).
  """
  @spec collect_entries_for_branch_summary(t(), String.t() | nil, String.t()) ::
          {[entry()], String.t() | nil}
  def collect_entries_for_branch_summary(_sm, nil, _target_id), do: {[], nil}

  def collect_entries_for_branch_summary(%__MODULE__{} = sm, old_leaf_id, target_id)
      when is_binary(old_leaf_id) and is_binary(target_id) do
    common_ancestor_id = find_common_ancestor(sm, old_leaf_id, target_id)

    entries =
      sm
      |> get_branch(old_leaf_id)
      |> entries_after_ancestor(common_ancestor_id)

    {entries, common_ancestor_id}
  end

  defp entries_after_ancestor(branch, nil), do: branch

  defp entries_after_ancestor(branch, ancestor_id) do
    branch
    |> Enum.drop_while(fn entry -> entry_id(entry) != ancestor_id end)
    |> tl_or_empty()
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  @doc """
  Assemble the LLM-ready session context from this manager's current
  branch. Walks root→leaf, collects messages, threads thinking-level
  and model selection across the path, and (when a CompactionEntry
  exists) places a synthetic CompactionSummaryMessage at the start of
  the kept-message window — skipping entries before
  `firstKeptEntryId`. Multiple compactions: the latest wins.

  Mirrors `buildSessionContext` (`session-manager.ts:315-422`); the
  ordering invariant verified at lines 390-392 (synthetic message
  goes at the START of kept, never interleaved).
  """
  @spec build_session_context(t(), String.t() | nil | :default) ::
          %{messages: [term()], thinking_level: String.t(), model: %{provider: String.t(), model_id: String.t()} | nil}
  def build_session_context(sm, leaf_id \\ :default)

  def build_session_context(%__MODULE__{}, nil) do
    # Explicit `nil` matches upstream's "navigated to before first
    # entry" sentinel — return an empty context.
    %{messages: [], thinking_level: "off", model: nil}
  end

  def build_session_context(%__MODULE__{by_id: by_id} = sm, :default) do
    do_build_context(by_id, resolve_leaf(sm, sm.leaf_id))
  end

  def build_session_context(%__MODULE__{by_id: by_id} = sm, leaf_id) when is_binary(leaf_id) do
    do_build_context(by_id, resolve_leaf(sm, leaf_id))
  end

  # leaf_id nil → fall back to latest body entry (mirrors `session-manager.ts:339`).
  defp resolve_leaf(sm, nil), do: latest_body_entry(sm)

  defp resolve_leaf(sm, id) do
    case Map.get(sm.by_id, id) do
      nil -> latest_body_entry(sm)
      entry -> entry
    end
  end

  defp latest_body_entry(%__MODULE__{file_entries: entries}) do
    entries |> Enum.reverse() |> Enum.find(fn e -> not match?(%Header{}, e) end)
  end

  defp do_build_context(_by_id, nil), do: %{messages: [], thinking_level: "off", model: nil}

  defp do_build_context(by_id, leaf) do
    path = walk_to_root(by_id, leaf, [])
    build_context_from_path(path)
  end

  @doc """
  Build the LLM context map from an already-walked root→leaf path
  list. Same shape as `build_session_context/2`, but consumed by
  the compaction layer (which receives `pathEntries` directly).
  """
  @spec build_context_from_path([Entry.t()]) ::
          %{messages: [term()], thinking_level: String.t(),
            model: %{provider: String.t(), model_id: String.t()} | nil}
  def build_context_from_path(path) when is_list(path) do
    {thinking_level, model, latest_compaction} = scan_settings(path)
    messages = build_messages(path, latest_compaction)
    %{messages: messages, thinking_level: thinking_level, model: model}
  end

  # Track thinking_level / model / latest CompactionEntry along path.
  defp scan_settings(path) do
    Enum.reduce(path, {"off", nil, nil}, fn entry, {tl, model, comp} ->
      case entry do
        %Entry.ThinkingLevelChange{} -> {entry.thinking_level, model, comp}
        %Entry.ModelChange{} -> {tl, %{provider: entry.provider, model_id: entry.model_id}, comp}
        %Entry.Message{message: %{"role" => "assistant"} = m} -> {tl, model_from_assistant(m, model), comp}
        %Entry.Compaction{} -> {tl, model, entry}
        _ -> {tl, model, comp}
      end
    end)
  end

  defp model_from_assistant(%{"provider" => provider, "model" => model_id}, _prev)
       when is_binary(provider) and is_binary(model_id),
       do: %{provider: provider, model_id: model_id}

  defp model_from_assistant(_msg, prev), do: prev

  # No compaction: emit messages in path order.
  defp build_messages(path, nil), do: Enum.flat_map(path, &entry_to_messages/1)

  # With compaction: synthetic summary + entries from firstKeptEntryId
  # forward to the compaction entry + entries after the compaction.
  defp build_messages(path, %Entry.Compaction{} = comp) do
    {before_comp, [_comp | after_comp]} =
      Enum.split_while(path, fn e -> entry_id(e) != comp.id end)

    kept = drop_until_id(before_comp, comp.first_kept_entry_id)

    summary_msg = CompactionSummaryMessage.new(comp.summary, comp.tokens_before, comp.timestamp)

    [summary_msg | Enum.flat_map(kept ++ after_comp, &entry_to_messages/1)]
  end

  defp drop_until_id(entries, target_id) do
    Enum.drop_while(entries, fn e -> entry_id(e) != target_id end)
  end

  @doc """
  Convert one path entry into the zero-or-one synthetic LLM
  message it contributes to context. Mirrors upstream's
  `getMessageFromEntry` (compaction.ts:79-93). Public so the
  compaction layer can reuse it on entry slices.
  """
  @spec entry_to_messages(Entry.t()) :: [map() | struct()]
  def entry_to_messages(%Entry.Message{message: msg}), do: [msg]

  def entry_to_messages(%Entry.BranchSummary{summary: s, from_id: f, timestamp: ts})
      when is_binary(s) and s != "" do
    [BranchSummaryMessage.new(s, f, ts)]
  end

  def entry_to_messages(%Entry.CustomMessage{} = e) do
    [
      %{
        role: "custom",
        custom_type: e.custom_type,
        content: e.content,
        display: e.display,
        details: e.details,
        timestamp: e.timestamp
      }
    ]
  end

  def entry_to_messages(_other), do: []

  @doc """
  Append an entry to the session: assign id (collision-checked),
  link `parent_id` to the current leaf, fill timestamp if absent,
  update the byId index + leaf pointer, and (when `:store` is
  given) persist via `SessionStore.append/2`.

  Mirrors the upstream `_appendEntry` flow
  (`session-manager.ts:821-826`) plus per-type appenders.

  Options:

    * `:id` — explicit id (skips generation).
    * `:timestamp` — explicit ISO-8601 timestamp (defaults to now).
    * `:store` — pid of an `OctoPi.Coder.SessionStore` to persist into.

  Returns `{updated_session_manager, entry_id}`.
  """
  @spec add_entry(t(), entry(), keyword()) :: {t(), String.t()}
  def add_entry(%__MODULE__{} = sm, entry, opts \\ []) do
    id = opts[:id] || unique_short_id(MapSet.new(Map.keys(sm.by_id)))
    parent_id = sm.leaf_id
    timestamp = opts[:timestamp] || iso8601_now()

    filled =
      entry
      |> set_id(id)
      |> set_parent_id(parent_id)
      |> ensure_timestamp(timestamp)

    if pid = opts[:store], do: SessionStore.append(pid, Entry.pairs(filled))

    sm = %{
      sm
      | by_id: Map.put(sm.by_id, id, filled),
        leaf_id: id,
        file_entries: sm.file_entries ++ [filled]
    }

    {sm, id}
  end

  defp ensure_timestamp(%Entry.Passthrough{raw: raw} = e, ts) do
    case Map.get(raw, "timestamp") do
      nil -> %{e | raw: Map.put(raw, "timestamp", ts)}
      _ -> e
    end
  end

  defp ensure_timestamp(entry, ts) do
    case Map.get(entry, :timestamp) do
      nil -> Map.put(entry, :timestamp, ts)
      _ -> entry
    end
  end

  defp iso8601_now, do: DateTime.to_iso8601(DateTime.utc_now())

  @doc """
  Fork an existing session into a new file under `target_dir`. The
  new file gets a fresh session id and `parentSession = source_path`,
  with all non-header entries copied verbatim. Returns the loaded
  `SessionManager` for the new file.

  Mirrors `SessionManager.forkFrom`
  (`session-manager.ts:1316-1357`).

  Errors:
    * `{:error, :enoent}` — source file does not exist
    * `{:error, :empty}` — source has no parseable lines
    * `{:error, :missing_header}` — source first entry is not a header
  """
  @spec fork(Path.t(), String.t(), Path.t(), keyword()) ::
          {:ok, t()} | {:error, :enoent | :empty | :missing_header}
  def fork(source_path, target_cwd, target_dir, opts \\ []) do
    with true <- File.exists?(source_path) || {:error, :enoent},
         entries when entries != [] <- source_path |> SessionStore.read_entries() |> Enum.to_list(),
         [%Header{} | body] <- entries do
      File.mkdir_p!(target_dir)

      new_id = opts[:id] || create_session_id()
      timestamp = opts[:timestamp] || iso8601_now()
      file_timestamp = timestamp |> String.replace(":", "-") |> String.replace(".", "-")
      new_path = Path.join(target_dir, "#{file_timestamp}_#{new_id}.jsonl")

      header = %Header{
        id: new_id,
        version: @current_version,
        timestamp: timestamp,
        cwd: target_cwd,
        parent_session: source_path
      }

      lines = [Header.encode(header) | Enum.map(body, &Entry.encode/1)]
      File.write!(new_path, Enum.join(lines, "\n") <> "\n")

      load(new_path)
    else
      {:error, _} = err -> err
      [] -> {:error, :empty}
      _ -> {:error, :missing_header}
    end
  end

  # Random UUID-shaped id (not a true v7 — just an opaque session
  # identifier, matching pi-mono's contract that ids are opaque
  # strings). 128 random bits formatted as 8-4-4-4-12.
  defp create_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  # ------- migration: v1 → v2 (assign id, parent_id, compaction id) -------

  defp ensure_ids(body, version) when version >= 2, do: body

  defp ensure_ids(body, _version) do
    {with_ids, _taken} =
      Enum.map_reduce(body, MapSet.new(), fn entry, taken ->
        id = unique_short_id(taken)
        {{entry, id}, MapSet.put(taken, id)}
      end)

    new_id_by_index = with_ids |> Enum.with_index() |> Map.new(fn {{_, id}, idx} -> {idx, id} end)

    {migrated, _last} =
      Enum.map_reduce(with_ids, nil, fn {entry, new_id}, prev_id ->
        migrated =
          entry
          |> set_id(new_id)
          |> set_parent_id(prev_id)
          |> migrate_compaction_index(new_id_by_index)

        {migrated, new_id}
      end)

    migrated
  end

  defp ensure_v3_roles(body, version) when version >= 3, do: body

  defp ensure_v3_roles(body, _version), do: Enum.map(body, &maybe_rename_hook_role/1)

  defp maybe_rename_hook_role(%Entry.Message{message: %{"role" => "hookMessage"} = msg} = e) do
    %{e | message: Map.put(msg, "role", "custom")}
  end

  defp maybe_rename_hook_role(other), do: other

  defp migrate_compaction_index(%Entry.Compaction{extras: %{"firstKeptEntryIndex" => idx}} = c, new_id_by_index)
       when is_integer(idx) do
    case Map.get(new_id_by_index, idx) do
      target_id when is_binary(target_id) ->
        %{c | first_kept_entry_id: target_id, extras: Map.delete(c.extras, "firstKeptEntryIndex")}

      _ ->
        %{c | extras: Map.delete(c.extras, "firstKeptEntryIndex")}
    end
  end

  defp migrate_compaction_index(other, _idx), do: other

  # ------- id helpers -------

  defp unique_short_id(taken) do
    Stream.repeatedly(&short_id/0) |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp short_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp set_id(%Entry.Passthrough{raw: raw} = e, id), do: %{e | raw: Map.put(raw, "id", id)}
  defp set_id(entry, id), do: Map.put(entry, :id, id)

  defp set_parent_id(%Entry.Passthrough{raw: raw} = e, pid), do: %{e | raw: Map.put(raw, "parentId", pid)}
  defp set_parent_id(entry, pid), do: Map.put(entry, :parent_id, pid)

  defp entry_id(%Entry.Passthrough{raw: raw}), do: raw["id"]
  defp entry_id(entry), do: Map.get(entry, :id)

  # ------- index -------

  defp index(body) do
    Enum.reduce(body, {%{}, nil}, fn entry, {map, _last} ->
      case entry_id(entry) do
        nil -> {map, nil}
        id -> {Map.put(map, id, entry), id}
      end
    end)
  end
end
