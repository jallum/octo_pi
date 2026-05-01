defmodule OctoPi.AI.Auth do
  @moduledoc """
  Resolves a runner's auth strategy to a credential string (or `nil`
  when none is needed).

  Strategy precedence:

    1. Override in `auth.json` keyed by *runner instance name* (the JSON
       key in `models.json`) — `{"my-anthropic": {"env": "FOO"}}`.
    2. The runner module's `auth/0` callback.

  Strategies recognised:

    * `:none`                — credential is `nil`
    * `{:env, "VAR"}`        — read `System.get_env/1`
    * `{:literal, "value"}`  — use the value verbatim
    * `{:cmd, "shell cmd"}`  — run via `System.shell/2`, return trimmed stdout

  ## Options

    * `:auth_file` — path to the auth.json file. Defaults to
      `Application.get_env(:octo_pi_ai, :auth_file)` and falls back to
      `~/.octo_pi/auth.json`. Pass `:none` to bypass auth.json entirely.
  """

  @type strategy :: OctoPi.AI.Runner.auth_strategy()
  @type result :: {:ok, String.t() | nil} | {:error, term()}

  @spec resolve(module(), String.t(), keyword()) :: result()
  def resolve(runner_module, runner_name, opts \\ []) when is_atom(runner_module) and is_binary(runner_name) do
    :telemetry.span(
      [:octo_pi_ai, :auth, :resolve],
      %{runner: runner_name},
      fn ->
        {strategy, result} = do_resolve(runner_module, runner_name, opts)

        meta = %{
          runner: runner_name,
          strategy: strategy_tag(strategy),
          outcome: outcome_tag(result)
        }

        {result, meta}
      end
    )
  end

  defp do_resolve(runner_module, runner_name, opts) do
    case choose_strategy(runner_module, runner_name, opts) do
      {:ok, strategy} -> {strategy, apply_strategy(strategy)}
      {:error, _} = err -> {:unknown, err}
    end
  end

  defp strategy_tag(:none), do: :none
  defp strategy_tag({:env, _}), do: :env
  defp strategy_tag({:literal, _}), do: :literal
  defp strategy_tag({:cmd, _}), do: :cmd
  defp strategy_tag(_), do: :unknown

  defp outcome_tag({:ok, _}), do: :ok
  defp outcome_tag({:error, _}), do: :error

  defp choose_strategy(runner_module, runner_name, opts) do
    case load_auth_overrides(opts) do
      {:ok, overrides} -> pick_strategy(overrides, runner_name, runner_module)
      {:error, _} = err -> err
    end
  end

  defp pick_strategy(overrides, runner_name, runner_module) do
    case Map.fetch(overrides, runner_name) do
      {:ok, raw} -> parse_override(raw, runner_name)
      :error -> {:ok, runner_module.auth()}
    end
  end

  defp parse_override(%{"literal" => v}, _name) when is_binary(v), do: {:ok, {:literal, v}}
  defp parse_override(%{"env" => v}, _name) when is_binary(v), do: {:ok, {:env, v}}
  defp parse_override(%{"cmd" => v}, _name) when is_binary(v), do: {:ok, {:cmd, v}}
  defp parse_override(%{"none" => true}, _name), do: {:ok, :none}
  defp parse_override(other, name), do: {:error, {:auth_json_invalid, name, other}}

  defp apply_strategy(:none), do: {:ok, nil}
  defp apply_strategy({:literal, v}), do: {:ok, v}

  defp apply_strategy({:env, var}) do
    case System.get_env(var) do
      nil -> {:error, {:env_unset, var}}
      "" -> {:error, {:env_unset, var}}
      v -> {:ok, v}
    end
  end

  defp apply_strategy({:cmd, cmd}) do
    {out, exit_code} = System.shell(cmd, stderr_to_stdout: true)

    case exit_code do
      0 -> {:ok, String.trim(out)}
      n -> {:error, {:cmd_failed, cmd, n, out}}
    end
  end

  defp load_auth_overrides(opts) do
    path = Keyword.get_lazy(opts, :auth_file, &default_auth_file/0)
    read_overrides(path)
  end

  defp read_overrides(:none), do: {:ok, %{}}

  defp read_overrides(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> decode_overrides(body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:auth_json_read, reason}}
    end
  end

  defp decode_overrides(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, {:auth_json_parse, :not_an_object}}
      {:error, err} -> {:error, {:auth_json_parse, err}}
    end
  end

  defp default_auth_file do
    Application.get_env(:octo_pi_ai, :auth_file) ||
      Path.expand("~/.octo_pi/auth.json")
  end
end
