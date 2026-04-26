defmodule OctoPi.Coder.Compaction do
  @moduledoc """
  Compaction orchestration. Port of upstream `compact`
  (`tmp/pi-mono/.../compaction/compaction.ts:717-797`).

  This module currently implements the **single-pass** path: a single
  `Summary.generate/4` call over `messages_to_summarize`, with file-op
  blocks appended. The split-turn / parallel-summaries branch is the
  subject of a follow-up ticket — calls that land there return
  `{:error, :split_turn_not_implemented}` for now.
  """

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Compaction.{FileOps, Preparation, Result, Summary}

  @type opts :: [
          api_key: String.t() | nil,
          headers: map() | nil,
          custom_instructions: String.t() | nil,
          thinking_level: atom() | nil,
          producer: module() | function()
        ]

  @spec compact(Preparation.t(), Model.t(), opts()) ::
          {:ok, Result.t()} | {:error, term()}
  def compact(preparation, model, opts \\ [])

  def compact(%Preparation{split_turn?: true, turn_prefix_messages: [_ | _]}, _model, _opts),
    do: {:error, :split_turn_not_implemented}

  def compact(%Preparation{} = prep, %Model{} = model, opts) do
    summary_opts =
      [
        previous_summary: prep.previous_summary,
        custom_instructions: Keyword.get(opts, :custom_instructions),
        api_key: Keyword.get(opts, :api_key),
        headers: Keyword.get(opts, :headers),
        thinking_level: Keyword.get(opts, :thinking_level),
        producer: Keyword.get(opts, :producer)
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    with {:ok, body} <-
           Summary.generate(
             prep.messages_to_summarize,
             model,
             prep.settings.reserve_tokens,
             summary_opts
           ) do
      lists = FileOps.compute_lists(prep.file_ops)
      summary = body <> FileOps.format(lists.read_files, lists.modified_files)

      details = %{
        "readFiles" => lists.read_files,
        "modifiedFiles" => lists.modified_files
      }

      {:ok,
       %Result{
         summary: summary,
         first_kept_entry_id: prep.first_kept_entry_id,
         tokens_before: prep.tokens_before,
         details: details
       }}
    end
  end
end
