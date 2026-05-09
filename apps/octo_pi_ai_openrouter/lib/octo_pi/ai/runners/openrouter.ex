defmodule OctoPi.AI.Runners.OpenRouter do
  @moduledoc """
  Runner for [OpenRouter](https://openrouter.ai), a unified gateway to
  hundreds of LLMs.

  Speaks the `:openai_completions` wire codec (`OctoPi.AI.Providers.OpenAI`).
  Auth defaults to `OPENROUTER_API_KEY`. The catalog is discoverable via
  OpenRouter's `/api/v1/models` endpoint, and individual models can be
  looked up via `/api/v1/models/<id>`.
  """

  @behaviour OctoPi.AI.Runner

  alias OctoPi.AI.Model

  @base_url "https://openrouter.ai/api/v1"

  @impl true
  def api, do: :openai_completions

  @impl true
  def default_base_url, do: @base_url

  @impl true
  def auth, do: {:env, "OPENROUTER_API_KEY"}

  @impl true
  def validate(%{"base_url" => v}) when not is_binary(v), do: {:error, "base_url must be a string"}

  def validate(_config), do: :ok

  @impl true
  def lookup(id, config) when is_binary(id) and is_map(config) do
    # OpenRouter's /models/<id> endpoint doesn't support individual lookups,
    # so we fetch the full catalog and filter by id.
    base_url = effective_base_url(config)

    case discover(config) do
      {:ok, models} -> find_model_by_id(models, id, base_url)
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_model_by_id(models, id, base_url) do
    case Enum.find(models, fn m -> m.id == id end) do
      %Model{} = model -> {:ok, %{model | base_url: base_url}}
      nil -> :not_found
    end
  end

  @impl true
  def discover(config) when is_map(config) do
    base_url = effective_base_url(config)
    url = "#{base_url}/models"

    case req_get(url, config) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        models =
          data
          |> Enum.map(&build_model(&1, base_url))
          |> Enum.reject(&is_nil/1)

        {:ok, models}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:bad_response, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp effective_base_url(%{"base_url" => v}) when is_binary(v), do: v
  defp effective_base_url(_), do: default_base_url()

  defp req_get(url, _config) do
    headers = [
      {"HTTP-Referer", "https://github.com/jallum/octo_pi"},
      {"X-Title", "OctoPi"}
    ]

    Req.get(url, [decode_json: [keys: :strings], headers: headers] ++ req_overrides())
  end

  defp req_overrides do
    Application.get_env(:octo_pi_ai, :req_overrides, [])
  end

  defp build_model(%{"id" => id} = data, base_url) do
    context_window = get_in(data, ["context_length"]) || 128_000

    %Model{
      id: id,
      name: Map.get(data, "name", id),
      api: :openai_completions,
      provider: :openrouter,
      base_url: base_url,
      reasoning: reasoning?(data),
      input: input_modalities(data),
      context_window: context_window,
      max_tokens: max_tokens(data, context_window),
      compat: %{
        thinking_format: :openrouter,
        open_router_routing: open_router_routing(data)
      }
    }
  end

  defp build_model(_data, _base_url), do: nil

  defp reasoning?(data) do
    supported_params = Map.get(data, "supported_parameters", [])
    "reasoning" in supported_params
  end

  defp input_modalities(%{"architecture" => %{"modality" => modality}}) do
    case modality do
      "multimodal" -> [:text, :image]
      _ -> [:text]
    end
  end

  defp input_modalities(_), do: [:text]

  defp max_tokens(data, context_window) do
    default = floor(context_window * 0.5)
    Map.get(data, "max_completion_tokens", default)
  end

  defp open_router_routing(data) do
    recommended = data |> Map.get("recommended_routing", %{}) |> clean_routing()

    data
    |> Map.get("routing", %{})
    |> Map.merge(recommended)
    |> Map.take(["provider", "allow_fallbacks", "ignore_capabilities"])
    |> sanitize_routing()
  end

  defp clean_routing(nil), do: %{}
  defp clean_routing(map) when is_map(map), do: map
  defp clean_routing(_), do: %{}

  defp sanitize_routing(map) do
    Map.new(map, fn
      {"provider", v} when is_map(v) -> {"provider", sanitize_provider(v)}
      pair -> pair
    end)
  end

  defp sanitize_provider(%{"name" => _name} = p) do
    p
    |> Map.take(["name", "quota", "context_length"])
    |> Map.update("quota", nil, &when_number_or_nil/1)
    |> Map.update("context_length", nil, &when_number_or_nil/1)
  end

  defp sanitize_provider(_), do: %{}

  defp when_number_or_nil(v) when is_number(v), do: v
  defp when_number_or_nil(_), do: nil
end
