defmodule OctoPi.Coder.Extensions.CustomCompaction do
  @moduledoc """
  Replaces default compaction with a full-context summary.

  Uses `ctx.find_model` and `ctx.get_model_auth` to look up an alternative
  model (e.g. Gemini Flash) for LLM-based summarization. When the registry
  is configured and auth succeeds, that model is preferred; until the LLM
  call is wired in, falls back to a local summary. When the registry is
  absent, falls back immediately without notifying.

  Returns `{:override, %Compaction.Result{}}` to supply an extension-built
  result; `Dispatcher.halt_on_result/3` (opi-ixp.46) surfaces the value to
  `Coder.Session.compact/2` (opi-ixp.23), which then writes the entry as
  `from_hook?: true` (opi-ixp.25). Ported from
  `examples/extensions/custom-compaction.ts`.
  """

  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Extension.API

  @summarization_provider :google
  @summarization_model_id "gemini-2.5-flash"

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.on(api, :session_before_compact, fn event, ctx -> compact(event, ctx) end)
  end

  defp compact(%{preparation: preparation}, ctx) do
    %{
      messages_to_summarize: msgs,
      tokens_before: tokens_before,
      first_kept_entry_id: first_kept_entry_id,
      previous_summary: previous_summary
    } = preparation

    try_alternative_model(ctx)

    case build_summary(msgs, previous_summary) do
      nil ->
        nil

      summary ->
        {:override,
         %Result{
           summary: summary,
           first_kept_entry_id: first_kept_entry_id,
           tokens_before: tokens_before,
           details: nil
         }}
    end
  end

  defp try_alternative_model(ctx) do
    with %{} = model <- ctx.find_model.(@summarization_provider, @summarization_model_id),
         {:ok, _auth} <- ctx.get_model_auth.(model) do
      :found
    else
      _ -> :unavailable
    end
  end

  defp build_summary([], _previous), do: nil

  defp build_summary(msgs, previous_summary) do
    count = length(msgs)
    context = if previous_summary, do: "\n\n#{previous_summary}", else: ""
    "Summary of #{count} message(s) from this session.#{context}"
  end
end
