defmodule OctoPi.Coder.Models do
  @moduledoc """
  Model registry — maps `(provider, id)` pairs to fully-populated
  `OctoPi.AI.Model` structs that the AI layer can consume.

  This is the seed implementation: a hard-coded table for the
  providers that ship in this umbrella (Anthropic + Ollama via
  OpenAI-compat). Unknown pairs return `nil`, mirroring upstream
  `findModel` semantics in `pi-mono`.

  Reused in two places:
  - `OctoPi.Coder.Extension.Context`'s default `find_model` callback
    so extensions like `CustomCompaction` can resolve alternate models
    without a per-session injection.
  - `OctoPi.Coder.CLI`'s model resolution path for the `--model` flag.
  """

  alias OctoPi.AI.Model

  @spec find(atom(), String.t()) :: Model.t() | nil
  def find(:anthropic, id) when is_binary(id), do: anthropic_model(id)
  def find(:ollama, id) when is_binary(id), do: ollama_model(id)
  def find(_provider, _id), do: nil

  @doc """
  Resolve a model from a bare id by sniffing the provider prefix.
  Used by the CLI's `--model` flag where the user supplies just the id.
  """
  @spec resolve(String.t()) :: Model.t() | nil
  def resolve(id) when is_binary(id), do: find(provider_from_id(id), id)

  defp provider_from_id("claude" <> _), do: :anthropic
  defp provider_from_id(_), do: :ollama

  defp anthropic_model(id) do
    base = %Model{
      id: id,
      name: id,
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 8_000
    }

    apply_anthropic_overrides(base, id)
  end

  defp apply_anthropic_overrides(base, "claude-sonnet" <> _),
    do: %{base | max_tokens: 64_000}

  defp apply_anthropic_overrides(base, "claude-opus" <> _),
    do: %{base | max_tokens: 32_000, reasoning: true}

  defp apply_anthropic_overrides(base, _), do: base

  defp ollama_model(id) do
    %Model{
      id: id,
      name: id,
      api: :openai_completions,
      provider: :ollama,
      base_url: "http://localhost:1234/v1",
      context_window: 262_144,
      max_tokens: 4_096
    }
  end
end
