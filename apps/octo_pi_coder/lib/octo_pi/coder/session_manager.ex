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
  alias OctoPi.Coder.Session.TreeNode
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
    labels_by_id: %{},
    label_timestamps_by_id: %{},
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
          labels_by_id: %{optional(String.t()) => String.t()},
          label_timestamps_by_id: %{optional(String.t()) => String.t()},
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

  @doc """
  Find the most recent valid session file in `session_dir`, sorted by
  mtime descending. Returns the path or `nil` when none exists.

  Mirrors upstream `findMostRecentSession`
  (`tmp/pi-mono/.../core/session-manager.ts:481-494`).
  """
  @spec find_recent(Path.t()) :: Path.t() | nil
  def find_recent(session_dir) do
    case File.ls(session_dir) do
      {:error, _} ->
        nil

      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(session_dir, &1))
        |> Enum.filter(&valid_session_file?/1)
        |> Enum.sort_by(&mtime/1, :desc)
        |> List.first()
    end
  end

  defp valid_session_file?(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, io} ->
        line = IO.read(io, :line)
        File.close(io)
        is_binary(line) and match?({:ok, %{"type" => "session"}}, Jason.decode(line))

      _ ->
        false
    end
  end

  defp mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> {{0, 0, 0}, {0, 0, 0}}
    end
  end

  defp from_entries([], _path), do: {:error, :empty}

  defp from_entries([%Header{} = header | body], path) do
    source_version = header.version || 1
    body_v2 = ensure_ids(body, source_version)
    body_v3 = ensure_v3_roles(body_v2, source_version)
    {by_id, labels_by_id, label_timestamps_by_id, leaf_id} = index(body_v3)
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
       labels_by_id: labels_by_id,
       label_timestamps_by_id: label_timestamps_by_id,
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
  Look up a single entry by id. Returns `nil` when not found.
  Mirrors `getEntry(id)` (`session-manager.ts:1024`).
  """
  @spec get_entry(t(), String.t()) :: entry() | nil
  def get_entry(%__MODULE__{by_id: by_id}, id) when is_binary(id), do: Map.get(by_id, id)

  @doc """
  Walk from a leaf entry toward root and return the slice in root→leaf
  order. Single read primitive used by branch reads, branch-switch, and
  compaction.

  ## Arguments

    * `leaf` — `:leaf` resolves to the manager's current leaf id, or a
      specific entry id to walk from.

  ## Options

    * `:to` — stop anchor (default `:root`):
      * `:root` — walk all the way to a root entry (parent_id == nil
        or pointing at a missing ancestor)
      * `:latest_compaction` — stop at the **latest compaction's
        `first_kept_entry_id`** (inclusive). This includes the kept
        window (`first_kept_entry_id..compaction`) plus everything
        after the compaction — matching upstream's
        `prepareCompaction` boundary (`compaction.ts:622-637`) and
        keeping `build_session_context`'s "summary + kept window +
        tail" emission well-defined. Falls back to the compaction
        itself if its `first_kept_entry_id` is not on the path; falls
        back to `:root` when no compaction exists.
      * a binary id — stop at the entry with that id (inclusive).
        Falls back to `:root` when the id is not on the path.

  Returns `[]` when no leaf exists or the leaf id is unknown. Orphaned
  ancestors (parent_id pointing to a missing entry) terminate the walk
  early so the returned path is always a contiguous chain.
  """
  @spec path(t(), :leaf | String.t() | nil, keyword()) :: [entry()]
  def path(sm, leaf \\ :leaf, opts \\ [])

  def path(%__MODULE__{leaf_id: leaf_id} = sm, :leaf, opts), do: path(sm, leaf_id, opts)
  def path(%__MODULE__{}, nil, _opts), do: []

  def path(%__MODULE__{by_id: by_id}, leaf_id, opts) when is_binary(leaf_id) do
    full = walk_to_anchor(by_id, Map.get(by_id, leaf_id), &never_stop/1, [])
    apply_to_anchor(full, Keyword.get(opts, :to, :root))
  end

  defp never_stop(_entry), do: false

  defp apply_to_anchor(full, :root), do: full

  defp apply_to_anchor(full, :latest_compaction) do
    case latest_compaction_anchor_id(full) do
      nil -> full
      anchor_id -> drop_before_id(full, anchor_id)
    end
  end

  defp apply_to_anchor(full, id) when is_binary(id) do
    case drop_before_id(full, id) do
      [] -> full
      sliced -> sliced
    end
  end

  defp latest_compaction_anchor_id(full) do
    full
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Entry.Compaction{first_kept_entry_id: fk} when is_binary(fk) -> fk
      %Entry.Compaction{} = c -> entry_id(c)
      _ -> nil
    end)
  end

  defp drop_before_id(entries, id) do
    Enum.drop_while(entries, fn e -> entry_id(e) != id end)
  end

  defp walk_to_anchor(_by_id, nil, _pred, acc), do: acc

  defp walk_to_anchor(by_id, entry, pred, acc) do
    acc = [entry | acc]

    if pred.(entry) do
      acc
    else
      parent_id = entry_parent(entry)
      parent = parent_id && Map.get(by_id, parent_id)
      walk_to_anchor(by_id, parent, pred, acc)
    end
  end

  @doc """
  Walk from the current leaf to root and return the path in root→leaf
  order. Returns `[]` when the session has no leaf. Equivalent to
  `path(sm, :leaf, to: :root)`.
  """
  @spec get_branch(t()) :: [entry()]
  def get_branch(%__MODULE__{} = sm), do: path(sm, :leaf, to: :root)

  @doc """
  Walk from the given entry id to root. Equivalent to
  `path(sm, from_id, to: :root)`.
  """
  @spec get_branch(t(), String.t()) :: [entry()]
  def get_branch(%__MODULE__{} = sm, from_id) when is_binary(from_id), do: path(sm, from_id, to: :root)

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
    old_ids = sm |> get_branch(old_leaf_id) |> MapSet.new(&entry_id/1)

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
    path = walk_to_anchor(by_id, leaf, &never_stop/1, [])
    build_context_from_path(path)
  end

  @doc """
  Build the LLM context map from an already-walked root→leaf path
  list. Same shape as `build_session_context/2`, but consumed by
  the compaction layer (which receives `pathEntries` directly).
  """
  @spec build_context_from_path([Entry.t()]) ::
          %{messages: [term()], thinking_level: String.t(), model: %{provider: String.t(), model_id: String.t()} | nil}
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
       when is_binary(provider) and is_binary(model_id), do: %{provider: provider, model_id: model_id}

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

  def entry_to_messages(%Entry.BranchSummary{summary: s, from_id: f, timestamp: ts}) when is_binary(s) and s != "" do
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
  and update the byId index + leaf pointer.

  Pure update on the in-memory struct — no IO. Persistence is the
  caller's responsibility (typically `OctoPi.Coder.SessionStore`,
  which wraps this and writes the materialized entry to its file).

  Mirrors the upstream `_appendEntry` flow
  (`session-manager.ts:821-826`) plus per-type appenders.

  Options:

    * `:id` — explicit id (skips generation).
    * `:timestamp` — explicit ISO-8601 timestamp (defaults to now).

  Returns `{updated_session_manager, materialized_entry}` — the entry
  with `id` / `parent_id` / `timestamp` filled in.
  """
  @spec add_entry(t(), entry(), keyword()) :: {t(), entry()}
  def add_entry(%__MODULE__{} = sm, entry, opts \\ []) do
    id = opts[:id] || unique_short_id(MapSet.new(Map.keys(sm.by_id)))
    parent_id = sm.leaf_id
    timestamp = opts[:timestamp] || iso8601_now()

    filled =
      entry
      |> set_id(id)
      |> set_parent_id(parent_id)
      |> ensure_timestamp(timestamp)

    sm = %{
      sm
      | by_id: Map.put(sm.by_id, id, filled),
        leaf_id: id,
        file_entries: sm.file_entries ++ [filled]
    }

    {sm, filled}
  end

  @doc """
  Move the leaf pointer without appending an entry. Used by branch
  navigation: after walking to a different node, the next append should
  be a child of *that* node. Pure update; no IO.

  Returns the updated session manager.
  """
  @spec set_leaf(t(), String.t() | nil) :: t()
  def set_leaf(%__MODULE__{} = sm, leaf_id), do: %{sm | leaf_id: leaf_id}

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
    (&short_id/0) |> Stream.repeatedly() |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp short_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp set_id(%Entry.Passthrough{raw: raw} = e, id), do: %{e | raw: Map.put(raw, "id", id)}
  defp set_id(entry, id), do: Map.put(entry, :id, id)

  defp set_parent_id(%Entry.Passthrough{raw: raw} = e, pid), do: %{e | raw: Map.put(raw, "parentId", pid)}
  defp set_parent_id(entry, pid), do: Map.put(entry, :parent_id, pid)

  defp entry_id(%Entry.Passthrough{raw: raw}), do: raw["id"]
  defp entry_id(entry), do: Map.get(entry, :id)

  # ------- label API -------

  @doc """
  Get the current label for an entry, or `nil` if none.
  Mirrors `getLabel()` in session-manager.ts:997.
  """
  @spec get_label(t(), String.t()) :: String.t() | nil
  def get_label(%__MODULE__{labels_by_id: m}, id), do: Map.get(m, id)

  @doc """
  Append a label change entry. Pass `nil` to clear a label.
  Raises if `target_id` is not a known entry.
  Mirrors `appendLabelChange()` in session-manager.ts:1006-1031.
  """
  @spec append_label_change(t(), String.t(), String.t() | nil) :: {t(), Entry.Label.t()}
  def append_label_change(%__MODULE__{} = sm, target_id, label) do
    if !Map.has_key?(sm.by_id, target_id) do
      raise "Entry #{target_id} not found"
    end

    entry = %Entry.Label{id: nil, timestamp: nil, target_id: target_id, label: label}
    {sm, materialized} = add_entry(sm, entry)

    {labels, timestamps} =
      if label do
        {Map.put(sm.labels_by_id, target_id, label),
         Map.put(sm.label_timestamps_by_id, target_id, materialized.timestamp)}
      else
        {Map.delete(sm.labels_by_id, target_id), Map.delete(sm.label_timestamps_by_id, target_id)}
      end

    {%{sm | labels_by_id: labels, label_timestamps_by_id: timestamps}, materialized}
  end

  # ------- tree -------

  @doc """
  Build the full session tree as a list of root `TreeNode` structs, with
  labels resolved from the label maps. Entries without an id are ignored.
  Orphaned entries (parent not in by_id) are treated as roots. Children
  are sorted by timestamp ascending (oldest first, newest at bottom).

  Mirrors `getTree()` in session-manager.ts:1075-1115.
  """
  @spec get_tree(t()) :: [TreeNode.t()]
  def get_tree(%__MODULE__{} = sm) do
    entries = get_entries(sm)

    children_map =
      Enum.reduce(entries, %{}, fn entry, acc ->
        id = entry_id(entry)

        if id do
          parent_id = entry_parent(entry)

          bucket =
            cond do
              is_nil(parent_id) -> :root
              parent_id == id -> :root
              Map.has_key?(sm.by_id, parent_id) -> parent_id
              true -> :root
            end

          Map.update(acc, bucket, [entry], &[entry | &1])
        else
          acc
        end
      end)

    root_entries = children_map |> Map.get(:root, []) |> sort_by_timestamp()
    sorted_map = Map.new(children_map, fn {k, v} -> {k, sort_by_timestamp(v)} end)

    Enum.map(root_entries, &build_tree_node(&1, sorted_map, sm.labels_by_id, sm.label_timestamps_by_id))
  end

  defp build_tree_node(entry, children_map, labels, label_timestamps) do
    id = entry_id(entry)

    children =
      children_map
      |> Map.get(id, [])
      |> Enum.map(&build_tree_node(&1, children_map, labels, label_timestamps))

    %TreeNode{
      entry: entry,
      children: children,
      label: Map.get(labels, id),
      label_timestamp: Map.get(label_timestamps, id)
    }
  end

  defp sort_by_timestamp(entries) do
    Enum.sort_by(entries, &entry_timestamp/1)
  end

  defp entry_timestamp(%Entry.Passthrough{raw: r}), do: r["timestamp"]
  defp entry_timestamp(entry), do: Map.get(entry, :timestamp)

  # ------- index -------

  defp index(body) do
    Enum.reduce(body, {%{}, %{}, %{}, nil}, fn entry, {by_id, labels, timestamps, _last} ->
      case entry_id(entry) do
        nil ->
          {by_id, labels, timestamps, nil}

        id ->
          {labels, timestamps} = maybe_index_label(entry, labels, timestamps)
          {Map.put(by_id, id, entry), labels, timestamps, id}
      end
    end)
  end

  defp maybe_index_label(%Entry.Label{target_id: tid, label: label, timestamp: ts}, labels, timestamps)
       when is_binary(label) do
    {Map.put(labels, tid, label), Map.put(timestamps, tid, ts)}
  end

  defp maybe_index_label(%Entry.Label{target_id: tid}, labels, timestamps) do
    {Map.delete(labels, tid), Map.delete(timestamps, tid)}
  end

  defp maybe_index_label(_entry, labels, timestamps), do: {labels, timestamps}
end
