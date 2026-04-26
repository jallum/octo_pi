defmodule OctoPi.Coder.Models do
  @moduledoc """
  Model registry — maps `(provider, id)` pairs to fully-populated
  `OctoPi.AI.Model` structs that the AI layer can consume.

  This is the seed implementation: a hard-coded table for the
  providers that ship in this umbrella (Anthropic + Ollama via
  OpenAI-completions) plus nominal entries for OpenAI and Google so
  extensions like `CustomCompaction` can resolve their preferred
  alternates by id without per-session injection. Unknown pairs return
  `nil`, mirroring upstream `findModel` semantics in `pi-mono`.

  > Caveat for `:google`: the model entries return a valid `Model`
  > struct, but no Google streaming provider is registered in this
  > umbrella yet (`api: :google_generative_ai` is a placeholder atom).
  > A `OctoPi.AI.stream/3` call against a Google model will fail at
  > the provider-lookup step until an `octo_pi_ai_google` app ships
  > and registers the api. Callers like `CustomCompaction` correctly
  > fall back via `get_model_auth` failing in that case.

  Reused in two places:
  - `OctoPi.Coder.Extension.Context`'s default `find_model` callback
  - `OctoPi.Coder.CLI`'s `--model` flag resolution path
  """

  alias OctoPi.AI.Model

  @spec find(atom(), String.t()) :: Model.t() | nil
  def find(:anthropic, id) when is_binary(id), do: anthropic_model(id)
  def find(:ollama, id) when is_binary(id), do: ollama_model(id)
  def find(:openai, id) when is_binary(id), do: openai_model(id)
  def find(:google, id) when is_binary(id), do: google_model(id)
  def find(_provider, _id), do: nil

  @doc """
  Resolve a model from a bare id by sniffing the provider prefix.
  Used by the CLI's `--model` flag where the user supplies just the id.
  """
  @spec resolve(String.t()) :: Model.t() | nil
  def resolve(id) when is_binary(id), do: find(provider_from_id(id), id)

  defp provider_from_id("claude" <> _), do: :anthropic
  defp provider_from_id("gemini" <> _), do: :google
  defp provider_from_id("gpt-" <> _), do: :openai
  defp provider_from_id("o1" <> _), do: :openai
  defp provider_from_id("o3" <> _), do: :openai
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

  defp openai_model(id) do
    base = %Model{
      id: id,
      name: id,
      api: :openai_completions,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      context_window: 128_000,
      max_tokens: 16_384
    }

    apply_openai_overrides(base, id)
  end

  defp apply_openai_overrides(base, "o" <> _), do: %{base | reasoning: true}
  defp apply_openai_overrides(base, "gpt-5" <> _), do: %{base | reasoning: true}
  defp apply_openai_overrides(base, _), do: base

  defp google_model(id) do
    base = %Model{
      id: id,
      name: id,
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      context_window: 1_048_576,
      max_tokens: 8_192,
      input: [:text, :image]
    }

    apply_google_overrides(base, id)
  end

  defp apply_google_overrides(base, "gemini-2.5-pro" <> _),
    do: %{base | reasoning: true, max_tokens: 65_536}

  defp apply_google_overrides(base, "gemini-2.5-flash" <> _),
    do: %{base | reasoning: true}

  defp apply_google_overrides(base, _), do: base
end
