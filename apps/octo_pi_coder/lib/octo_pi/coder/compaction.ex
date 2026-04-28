defmodule OctoPi.Coder.Compaction do
  @moduledoc """
  Compaction orchestration. Port of upstream `compact`
  (`tmp/pi-mono/.../compaction/compaction.ts:717-797`).

  Two paths:

  - **single-pass** — one `Summary.generate/4` call over
    `messages_to_summarize`. Hit when the cut isn't a split turn (or it
    is, but `turn_prefix_messages` is empty).
  - **split-turn parallel** — history and turn-prefix summaries run in
    parallel via `Task.async/1` and are merged with the upstream
    separator: `\\n\\n---\\n\\n**Turn Context (split turn):**\\n\\n`.
    `custom_instructions` and `previous_summary` only flow into the
    history call; the turn-prefix call uses
    `Summary.generate(..., variant: :turn_prefix)` (0.5 × reserve).

  In both paths, `<read-files>` / `<modified-files>` blocks are appended
  to the resulting summary.
  """

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Compaction.FileOps
  alias OctoPi.Coder.Compaction.Preparation
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Compaction.Summary

  @turn_separator "\n\n---\n\n**Turn Context (split turn):**\n\n"

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

  def compact(%Preparation{} = prep, %Model{} = model, opts) do
    with {:ok, body} <- generate_body(prep, model, opts) do
      {:ok, build_result(prep, body)}
    end
  end

  # Single-pass: split_turn? is false OR there are no turn-prefix messages.
  defp generate_body(%Preparation{split_turn?: split?, turn_prefix_messages: tp} = prep, model, opts)
       when split? == false or tp == [] do
    Summary.generate(
      prep.messages_to_summarize,
      model,
      prep.settings.reserve_tokens,
      history_opts(prep, opts)
    )
  end

  # Split-turn parallel: history + turn-prefix run concurrently and are
  # merged with the upstream separator.
  defp generate_body(%Preparation{} = prep, %Model{} = model, opts) do
    history_task =
      Task.async(fn -> history_summary(prep, model, opts) end)

    turn_task =
      Task.async(fn ->
        Summary.generate(
          prep.turn_prefix_messages,
          model,
          prep.settings.reserve_tokens,
          turn_prefix_opts(opts)
        )
      end)

    case {Task.await(history_task, :infinity), Task.await(turn_task, :infinity)} do
      {{:ok, hist}, {:ok, turn}} -> {:ok, hist <> @turn_separator <> turn}
      {{:error, _} = err, _} -> err
      {_, {:error, _} = err} -> err
    end
  end

  # Upstream short-circuits the history call when there's nothing to
  # summarize, returning the literal "No prior history." (compaction.ts:743-755).
  defp history_summary(%Preparation{messages_to_summarize: []}, _model, _opts), do: {:ok, "No prior history."}

  defp history_summary(%Preparation{} = prep, %Model{} = model, opts) do
    Summary.generate(
      prep.messages_to_summarize,
      model,
      prep.settings.reserve_tokens,
      history_opts(prep, opts)
    )
  end

  defp history_opts(%Preparation{} = prep, opts) do
    Enum.reject(
      [
        previous_summary: prep.previous_summary,
        custom_instructions: Keyword.get(opts, :custom_instructions),
        api_key: Keyword.get(opts, :api_key),
        headers: Keyword.get(opts, :headers),
        thinking_level: Keyword.get(opts, :thinking_level),
        producer: Keyword.get(opts, :producer)
      ],
      fn {_, v} -> is_nil(v) end
    )
  end

  defp turn_prefix_opts(opts) do
    Enum.reject(
      [
        variant: :turn_prefix,
        api_key: Keyword.get(opts, :api_key),
        headers: Keyword.get(opts, :headers),
        thinking_level: Keyword.get(opts, :thinking_level),
        producer: Keyword.get(opts, :producer)
      ],
      fn {_, v} -> is_nil(v) end
    )
  end

  defp build_result(%Preparation{} = prep, body) do
    lists = FileOps.compute_lists(prep.file_ops)
    summary = body <> FileOps.format(lists.read_files, lists.modified_files)

    details = %{
      "readFiles" => lists.read_files,
      "modifiedFiles" => lists.modified_files
    }

    %Result{
      summary: summary,
      first_kept_entry_id: prep.first_kept_entry_id,
      tokens_before: prep.tokens_before,
      details: details
    }
  end
end
