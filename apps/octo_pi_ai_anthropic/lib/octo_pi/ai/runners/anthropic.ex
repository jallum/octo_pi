defmodule OctoPi.AI.Runners.Anthropic do
  @moduledoc """
  Runner for Anthropic's first-party Claude API.

  Speaks the `:anthropic_messages` wire codec
  (`OctoPi.AI.Providers.Anthropic`). Auth defaults to
  `ANTHROPIC_API_KEY`; the catalog is hand-curated in `models.json`
  (Anthropic doesn't expose a useful live `/models` endpoint to enumerate).
  """

  @behaviour OctoPi.AI.Runner

  @impl true
  def api, do: :anthropic_messages

  @impl true
  def default_base_url, do: "https://api.anthropic.com/v1"

  @impl true
  def auth, do: {:env, "ANTHROPIC_API_KEY"}

  @impl true
  def validate(%{"base_url" => v}) when not is_binary(v), do: {:error, "base_url must be a string"}

  def validate(_config), do: :ok

  @impl true
  def lookup(_id, _config), do: :unsupported

  @impl true
  def discover(_config), do: :unsupported
end
