defmodule OctoPi.AI.Runners.LMStudio do
  @moduledoc """
  Runner for a local [LM Studio](https://lmstudio.ai) server.

  Speaks the OpenAI-completions wire codec at `/v1`. Uses LM Studio's
  native `/api/v0/models` REST endpoint to populate `Model` structs
  with real `context_window` and capability data, since the
  OpenAI-compatible `/v1/models` doesn't expose those.

  No auth: LM Studio is local and accepts any (or no) bearer token.

  Test transport injection follows the umbrella convention: set
  `Application.put_env(:octo_pi_ai, :req_overrides, plug: my_plug)` to
  short-circuit Req against a `Plug` test server.
  """

  @behaviour OctoPi.AI.Runner

  alias OctoPi.AI.Model

  @impl true
  def api, do: :openai_completions

  @impl true
  def default_base_url, do: "http://localhost:1234/v1"

  @impl true
  def auth, do: :none

  @impl true
  def validate(%{"base_url" => v}) when not is_binary(v),
    do: {:error, "base_url must be a string"}

  def validate(_config), do: :ok

  @impl true
  def lookup(id, config) when is_binary(id) and is_map(config) do
    base_url = effective_base_url(config)
    url = catalog_url(base_url, id)

    try do
      case Req.get(url, req_overrides()) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, build_model(body, base_url)}

        {:ok, %{status: 404}} ->
          :not_found

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, err} ->
          {:error, err}
      end
    rescue
      err -> {:error, err}
    end
  end

  @impl true
  def discover(config) when is_map(config) do
    base_url = effective_base_url(config)
    url = catalog_url(base_url)

    try do
      case Req.get(url, req_overrides()) do
        {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
          {:ok, Enum.map(data, &build_model(&1, base_url))}

        {:ok, %{status: 200, body: body}} ->
          {:error, {:bad_response, body}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, err} ->
          {:error, err}
      end
    rescue
      err -> {:error, err}
    end
  end

  defp effective_base_url(%{"base_url" => v}) when is_binary(v), do: v
  defp effective_base_url(_), do: default_base_url()

  defp catalog_url(base_url) do
    base_url
    |> URI.parse()
    |> Map.put(:path, "/api/v0/models")
    |> Map.put(:query, nil)
    |> URI.to_string()
  end

  defp catalog_url(base_url, id) do
    base_url
    |> URI.parse()
    |> Map.put(:path, "/api/v0/models/#{id}")
    |> Map.put(:query, nil)
    |> URI.to_string()
  end

  defp build_model(%{"id" => id} = entry, base_url) do
    %Model{
      id: id,
      name: id,
      api: :openai_completions,
      provider: :lmstudio,
      base_url: base_url,
      reasoning: !!entry["reasoning"],
      input: input_modalities(entry),
      context_window: entry["max_context_length"] || entry["loaded_context_length"] || 8_192,
      max_tokens: entry["loaded_context_length"] || 4_096
    }
  end

  defp input_modalities(%{"vision" => true}), do: [:text, :image]
  defp input_modalities(_), do: [:text]

  defp req_overrides do
    [decode_json: [keys: :strings]] ++ Application.get_env(:octo_pi_ai, :req_overrides, [])
  end
end
