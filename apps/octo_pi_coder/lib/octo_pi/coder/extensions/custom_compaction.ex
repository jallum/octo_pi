defmodule OctoPi.Coder.Extensions.CustomCompaction do
  @moduledoc """
  Replaces default compaction with a full-context summary.

  Diverges from custom-compaction.ts: LLM summarization and model registry calls are
  not ported (TypeScript-specific). The summary is generated locally from preparation
  metadata. Returns {:cancel, compaction} to override the default compaction behavior.
  Ported from examples/extensions/custom-compaction.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :session_before_compact, fn event, _ctx -> compact(event) end)
  end

  defp compact(%{preparation: preparation}) do
    %{
      messages_to_summarize: msgs,
      tokens_before: tokens_before,
      first_kept_entry_id: first_kept_entry_id,
      previous_summary: previous_summary
    } = preparation

    case build_summary(msgs, previous_summary) do
      nil ->
        nil

      summary ->
        {:cancel,
         %{
           compaction: %{
             summary: summary,
             first_kept_entry_id: first_kept_entry_id,
             tokens_before: tokens_before
           }
         }}
    end
  end

  defp build_summary([], _previous), do: nil

  defp build_summary(msgs, previous_summary) do
    count = length(msgs)
    context = if previous_summary, do: "\n\n#{previous_summary}", else: ""
    "Summary of #{count} message(s) from this session.#{context}"
  end
end
