defmodule OctoPi.Coder.Tools.Bash do
  @moduledoc """
  `bash` built-in tool. Runs a shell command under `erlexec` with
  streaming stdout/stderr, a deadline, and cooperative abort.

  On timeout or abort, `:exec.stop/1` signals the direct child only;
  background jobs launched by the command (e.g. `bash -c "x & wait"`)
  can leak. We investigated enabling erlexec's `:kill_group` flag —
  it works for single invocations but destabilizes the `:exec`
  singleton when multiple commands run back-to-back in the same VM,
  crashing with `{:exit_status, N}`. Tracked as a known limitation;
  a proper fix needs either an upstream erlexec patch or a switch
  to a custom setpgid'ing port helper. See the discussion in
  `opi-dkl.5` for the reproduction.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.PathGuard

  @default_timeout_ms 120_000
  @abort_poll_ms 50
  @max_output_bytes 32 * 1024
  @max_output_lines 100

  @doc "Build a `%Tool{}` rooted at `cwd` — the bash `cwd` arg is resolved against it."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "bash",
      label: "Bash",
      description: "Run a shell command. Use for file operations, builds, tests, etc.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "cmd" => %{"type" => "string", "description" => "The shell command line."},
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory (must be within session cwd)."
          },
          "timeout_ms" => %{"type" => "integer", "description" => "Kill after this many ms."}
        },
        "required" => ["cmd"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"cmd" => cmd} = args, abort_ref, on_update) do
    session_cwd = Map.fetch!(args, "_cwd")
    timeout_ms = Map.get(args, "timeout_ms", @default_timeout_ms)

    case resolve_cwd(args, session_cwd) do
      {:error, %Result{} = r} -> {:ok, r}
      {:ok, cwd} -> run_with_cwd(cmd, cwd, timeout_ms, abort_ref, on_update)
    end
  end

  defp resolve_cwd(args, session_cwd) do
    case Map.get(args, "cwd") do
      nil -> {:ok, session_cwd}
      requested -> PathGuard.resolve_or_error(requested, session_cwd)
    end
  end

  defp run_with_cwd(cmd, cwd, timeout_ms, abort_ref, on_update) do
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:octo_pi_coder, :bash, :start],
      %{system_time: System.system_time()},
      %{cmd: cmd, cwd: cwd}
    )

    exec_opts = [
      :monitor,
      {:stdout, self()},
      {:stderr, self()},
      {:cd, to_charlist(cwd)}
      # `:kill_group` is omitted intentionally — see moduledoc.
    ]

    # `run/2` (no link) + `:monitor` — child exits propagate as
    # `:DOWN` messages to this process, not as link-exits that would
    # crash the loop task when the command returns non-zero.
    case :exec.run(String.to_charlist(cmd), exec_opts) do
      {:ok, pid, ospid} ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect(pid, ospid, abort_ref, on_update, deadline, "", "", start_mono)

      {:error, reason} ->
        emit_stop(:exec_failed, start_mono)

        {:ok,
         %Result{
           is_error?: true,
           content: [%Content.Text{text: "exec failed: #{inspect(reason)}"}]
         }}
    end
  end

  defp collect(pid, ospid, abort_ref, on_update, deadline, stdout_buf, stderr_buf, start_mono) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        :exec.stop(pid)
        emit_stop(:timeout, start_mono)
        finalize(:timeout, stdout_buf, stderr_buf, nil)

      AbortRef.aborted?(abort_ref) ->
        :exec.stop(pid)
        emit_stop(:aborted, start_mono)
        finalize(:aborted, stdout_buf, stderr_buf, nil)

      true ->
        receive do
          {:stdout, ^ospid, data} ->
            new_buf = stdout_buf <> to_string(data)
            stream_update(on_update, new_buf, stderr_buf)
            collect(pid, ospid, abort_ref, on_update, deadline, new_buf, stderr_buf, start_mono)

          {:stderr, ^ospid, data} ->
            new_buf = stderr_buf <> to_string(data)
            stream_update(on_update, stdout_buf, new_buf)
            collect(pid, ospid, abort_ref, on_update, deadline, stdout_buf, new_buf, start_mono)

          {:DOWN, _mref, :process, ^pid, :normal} ->
            emit_stop(:ok, start_mono)
            finalize(:exit, stdout_buf, stderr_buf, 0)

          {:DOWN, _mref, :process, ^pid, {:exit_status, raw}} ->
            status = :exec.status(raw)
            code = normal_exit_code(status)
            emit_stop(:ok, start_mono)
            finalize(:exit, stdout_buf, stderr_buf, code)

          {:DOWN, _mref, :process, ^pid, _other} ->
            emit_stop(:crashed, start_mono)
            finalize(:exit, stdout_buf, stderr_buf, 1)
        after
          @abort_poll_ms ->
            collect(
              pid,
              ospid,
              abort_ref,
              on_update,
              deadline,
              stdout_buf,
              stderr_buf,
              start_mono
            )
        end
    end
  end

  defp normal_exit_code({:status, code}), do: code
  defp normal_exit_code({:signal, _sig, _core}), do: 1

  defp stream_update(on_update, stdout_buf, stderr_buf) do
    on_update.(%Result{
      content: [%Content.Text{text: render_output(stdout_buf, stderr_buf)}]
    })
  end

  defp finalize(reason, stdout_buf, stderr_buf, code) do
    text = render_output(stdout_buf, stderr_buf)

    {text, truncation} = maybe_truncate(text)

    details =
      %{exit_status: code, reason: reason}
      |> Map.merge(truncation)

    {:ok,
     %Result{
       is_error?: reason != :exit or (is_integer(code) and code != 0),
       content: [%Content.Text{text: text}],
       details: details
     }}
  end

  defp render_output(stdout_buf, ""), do: stdout_buf
  defp render_output("", stderr_buf), do: stderr_buf

  defp render_output(stdout_buf, stderr_buf),
    do: stdout_buf <> "\n--- stderr ---\n" <> stderr_buf

  defp maybe_truncate(text) do
    lines = String.split(text, "\n")
    line_count = length(lines)

    cond do
      byte_size(text) > @max_output_bytes ->
        {binary_part(text, 0, @max_output_bytes) <> "\n...truncated (byte limit)",
         %{truncated: true, truncated_by: :bytes}}

      line_count > @max_output_lines ->
        kept = Enum.take(lines, @max_output_lines)

        {Enum.join(kept, "\n") <> "\n...truncated #{line_count - @max_output_lines} lines",
         %{truncated: true, truncated_by: :lines}}

      true ->
        {text, %{truncated: false}}
    end
  end

  defp emit_stop(reason, start_mono) do
    event = if reason == :ok, do: :stop, else: reason

    :telemetry.execute(
      [:octo_pi_coder, :bash, event],
      %{duration: System.monotonic_time() - start_mono},
      %{reason: reason}
    )
  end
end
