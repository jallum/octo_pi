defmodule OctoPi.AI.ModelRegistry do
  @moduledoc """
  Loads `models.json` and resolves `(runner_name, model_id)` pairs to
  fully-populated `OctoPi.AI.Model` structs.

  See `opi-y1z` for the design. The registry is a plain struct returned
  from `load/1`; callers (typically the application) hold it and pass it
  to `find/3` / `resolve/2`. There's no implicit global — that's a
  separate convenience layer.

  ## File shape

      {
        "providers": {
          "anthropic": {
            "models": [
              { "id": "claude-opus-4-7", "context_window": 200000, ... }
            ]
          },
          "stub-laptop": {
            "runner": "stub",
            "base_url": "http://laptop.local/v1",
            "models": [{ "id": "qwen" }]
          }
        }
      }

  Top-level keys are *runner instance names*. They normally match a
  registered runner module by atom. To use a custom name, set
  `"runner": "<atom>"` to point at the underlying runner kind.

  ## Resolve semantics

  `resolve/2` accepts strict `"runner/model-id"` form. On miss in the
  loaded catalog, it consults the runner module's `lookup/2`. The
  returned `Model.t()` is *not* persisted; callers decide whether to
  write it back to `models.json`.
  """

  alias OctoPi.AI.Model

  @enforce_keys [:by_pair, :runner_module]
  defstruct [:by_pair, :runner_module]

  @type t :: %__MODULE__{
          by_pair: %{{atom(), String.t()} => Model.t()},
          runner_module: %{atom() => module()}
        }

  @default_context_window 128_000
  @default_max_tokens 16_384

  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    runners = Keyword.get_lazy(opts, :runners, &OctoPi.AI.RunnerRegistry.list/0)
    path = Keyword.get_lazy(opts, :models_file, &default_models_file/0)

    :telemetry.span(
      [:octo_pi_ai, :model_registry, :load],
      %{path: path},
      fn ->
        result = do_load(path, runners)
        {result, load_meta(result, path)}
      end
    )
  end

  defp do_load(path, runners) do
    with {:ok, json} <- read_json(path),
         {:ok, providers} <- check_top_level(json),
         {:ok, entries, instance_modules} <- parse_entries(providers, runners) do
      build_registry(entries, runners, instance_modules)
    end
  end

  defp load_meta({:ok, %__MODULE__{by_pair: by_pair} = reg}, path) do
    %{
      path: path,
      outcome: :ok,
      runner_count: length(runners(reg)),
      model_count: map_size(by_pair)
    }
  end

  defp load_meta({:error, reason}, path) do
    %{path: path, outcome: :error, reason: reason}
  end

  @spec find(t(), atom(), String.t()) :: Model.t() | nil
  def find(%__MODULE__{by_pair: by_pair}, runner_name, id) when is_atom(runner_name) and is_binary(id) do
    Map.get(by_pair, {runner_name, id})
  end

  @spec resolve(t(), String.t()) :: {:ok, Model.t()} | {:error, term()}
  def resolve(%__MODULE__{} = reg, ref) when is_binary(ref) do
    :telemetry.span(
      [:octo_pi_ai, :model_registry, :resolve],
      %{ref: ref},
      fn ->
        tagged = do_resolve_top(reg, ref)
        {strip_tag(tagged), resolve_meta(ref, tagged)}
      end
    )
  end

  # Returns one of:
  #   {:ok, :cached, %Model{}}
  #   {:ok, :looked_up, %Model{}}
  #   {:error, {:bad_ref, ref}}
  #   {:error, {:not_found, runner, id}}
  #   {:error, {:unsupported, runner, id}}
  #   {:error, {:unknown_runner, name}}
  defp do_resolve_top(reg, ref) do
    with {:ok, runner_name, id} <- parse_ref(ref) do
      do_resolve(reg, runner_name, id)
    end
  end

  defp do_resolve(reg, runner_name, id) do
    case find(reg, runner_name, id) do
      %Model{} = model -> {:ok, :cached, model}
      nil -> resolve_via_runner(reg, runner_name, id)
    end
  end

  defp strip_tag({:ok, _outcome, model}), do: {:ok, model}
  defp strip_tag(other), do: other

  defp resolve_meta(ref, {:ok, outcome, _model}), do: %{ref: ref, outcome: outcome}
  defp resolve_meta(ref, {:error, {:bad_ref, _}}), do: %{ref: ref, outcome: :bad_ref}

  defp resolve_meta(ref, {:error, {:not_found, runner, id}}),
    do: %{ref: ref, outcome: :not_found, runner: runner, id: id}

  defp resolve_meta(ref, {:error, {:unsupported, runner, id}}),
    do: %{ref: ref, outcome: :unsupported, runner: runner, id: id}

  defp resolve_meta(ref, {:error, {:unknown_runner, name}}), do: %{ref: ref, outcome: :unknown_runner, runner: name}

  defp resolve_via_runner(%__MODULE__{runner_module: rmap}, runner_name, id) do
    case Map.fetch(rmap, runner_name) do
      :error -> {:error, {:unknown_runner, Atom.to_string(runner_name)}}
      {:ok, module} -> dispatch_lookup(module, runner_name, id)
    end
  end

  defp dispatch_lookup(module, runner_name, id) do
    :telemetry.span(
      [:octo_pi_ai, :runner, :lookup],
      %{runner: runner_name, id: id},
      fn ->
        result = module.lookup(id, %{})
        {translate_lookup(result, runner_name, id), lookup_meta(result, runner_name, id)}
      end
    )
  end

  defp translate_lookup({:ok, %Model{} = m}, runner_name, _id), do: {:ok, :looked_up, %{m | provider: runner_name}}

  defp translate_lookup(:not_found, runner_name, id), do: {:error, {:not_found, runner_name, id}}
  defp translate_lookup(:unsupported, runner_name, id), do: {:error, {:unsupported, runner_name, id}}

  defp lookup_meta({:ok, _}, runner_name, id), do: %{runner: runner_name, id: id, outcome: :ok}
  defp lookup_meta(:not_found, runner_name, id), do: %{runner: runner_name, id: id, outcome: :not_found}
  defp lookup_meta(:unsupported, runner_name, id), do: %{runner: runner_name, id: id, outcome: :unsupported}

  @spec runners(t()) :: [atom()]
  def runners(%__MODULE__{by_pair: by_pair}) do
    by_pair |> Map.keys() |> Enum.map(fn {r, _} -> r end) |> Enum.uniq() |> Enum.sort()
  end

  @spec models(t(), atom()) :: [Model.t()]
  def models(%__MODULE__{by_pair: by_pair}, runner_name) when is_atom(runner_name) do
    by_pair
    |> Enum.filter(fn {{r, _}, _} -> r == runner_name end)
    |> Enum.map(fn {_, m} -> m end)
  end

  @spec all(t()) :: [Model.t()]
  def all(%__MODULE__{by_pair: by_pair}), do: Map.values(by_pair)

  @persistent_term_key :octo_pi_ai_model_registry_global

  @doc """
  Lazily-loaded process-global registry, cached in `:persistent_term`.

  Reads `~/.octo_pi/models.json` (or the `:models_file` app env)
  and registers via `RunnerRegistry`. Use `reset_global!/0` in tests to
  re-load from a different file.

  Raises if loading fails — callers that want graceful degradation
  should use `load/1` directly.
  """
  @spec global!() :: t()
  def global!, do: do_global(:persistent_term.get(@persistent_term_key, :unset))

  defp do_global(:unset) do
    case load([]) do
      {:ok, reg} ->
        :persistent_term.put(@persistent_term_key, reg)
        reg

      {:error, reason} ->
        raise ArgumentError, "ModelRegistry.global!/0 failed to load: #{inspect(reason)}"
    end
  end

  defp do_global(%__MODULE__{} = reg), do: reg

  @doc "Drop the persistent_term cache. Tests use this to swap models.json files."
  @spec reset_global!() :: :ok
  def reset_global! do
    :persistent_term.erase(@persistent_term_key)
    :ok
  end

  defp parse_ref(ref) do
    case String.split(ref, "/", parts: 2) do
      [runner, id] when runner != "" and id != "" ->
        {:ok, String.to_atom(runner), id}

      _ ->
        {:error, {:bad_ref, ref}}
    end
  end

  defp read_json(:none), do: {:ok, %{"providers" => %{}}}

  defp read_json(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> decode_json(body)
      {:error, :enoent} -> {:ok, %{"providers" => %{}}}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, term} -> {:ok, term}
      {:error, err} -> {:error, {:parse, err}}
    end
  end

  defp check_top_level(%{"providers" => providers}) when is_map(providers), do: {:ok, providers}
  defp check_top_level(_), do: {:error, {:schema, "expected top-level object with \"providers\" key"}}

  defp parse_entries(providers, runners) do
    providers
    |> Enum.reduce_while({:ok, [], %{}}, fn {key, entry}, {:ok, models_acc, modmap_acc} ->
      case parse_entry(key, entry, runners) do
        {:ok, models, runner_module} ->
          {:cont, {:ok, [models | models_acc], Map.put(modmap_acc, String.to_atom(key), runner_module)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, lists, modmap} -> {:ok, lists |> Enum.reverse() |> List.flatten(), modmap}
      err -> err
    end
  end

  defp parse_entry(key, entry, runners) when is_map(entry) do
    with {:ok, runner_module} <- resolve_runner_module(key, entry, runners),
         :ok <- runner_module.validate(entry),
         {:ok, models} <- build_models(key, entry, runner_module) do
      {:ok, models, runner_module}
    end
  end

  defp parse_entry(key, _entry, _runners), do: {:error, {:invalid_entry, key, "expected object"}}

  defp resolve_runner_module(key, entry, runners) do
    kind_name = Map.get(entry, "runner") || key
    kind_atom = safe_atom(kind_name)

    case Map.fetch(runners, kind_atom) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_runner, kind_name}}
    end
  end

  defp safe_atom(s) when is_binary(s), do: String.to_atom(s)

  defp build_models(key, entry, runner_module) do
    runner_name = String.to_atom(key)
    base_url = Map.get(entry, "base_url") || runner_module.default_base_url()
    api = api_atom(entry, runner_module)
    models_raw = Map.get(entry, "models", [])

    models_raw
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case build_one_model(raw, runner_name, api, base_url) do
        {:ok, m} -> {:cont, {:ok, [m | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_model, key, raw, reason}}}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      err -> err
    end
  end

  defp api_atom(%{"api" => a}, _runner_module) when is_binary(a), do: String.to_atom(a)
  defp api_atom(_, runner_module), do: runner_module.api()

  defp build_one_model(%{"id" => id} = raw, runner_name, api, base_url) when is_binary(id) and id != "" do
    {:ok,
     %Model{
       id: id,
       name: Map.get(raw, "name", id),
       api: api,
       provider: runner_name,
       base_url: base_url,
       reasoning: Map.get(raw, "reasoning", false),
       input: parse_input(Map.get(raw, "input", ["text"])),
       context_window: Map.get(raw, "context_window", @default_context_window),
       max_tokens: Map.get(raw, "max_tokens", @default_max_tokens),
       compat: Map.get(raw, "compat")
     }}
  end

  defp build_one_model(_raw, _runner_name, _api, _base_url), do: {:error, "missing id"}

  defp parse_input(list) when is_list(list), do: Enum.map(list, &String.to_atom/1)

  defp build_registry(entries, runners, instance_modules) do
    by_pair =
      Map.new(entries, fn %Model{provider: r, id: i} = m -> {{r, i}, m} end)

    {:ok, %__MODULE__{by_pair: by_pair, runner_module: Map.merge(runners, instance_modules)}}
  end

  defp default_models_file do
    Application.get_env(:octo_pi_ai, :models_file) ||
      Path.expand("~/.octo_pi/models.json")
  end
end
