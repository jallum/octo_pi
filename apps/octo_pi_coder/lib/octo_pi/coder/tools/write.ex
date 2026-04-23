defmodule OctoPi.Coder.Tools.Write do
  @moduledoc """
  `write` built-in tool. Writes content to a path, creating
  intermediate directories as needed. Goes through `FileMutex` so
  concurrent writers don't race.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.FileMutex
  alias OctoPi.Coder.Tools.PathGuard

  @doc "Build a `%Tool{}` rooted at `cwd` — paths are resolved against it and escapes rejected."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "write",
      label: "Write file",
      description: "Write content to a file, creating parent directories as needed.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path (resolved against session cwd)."},
          "content" => %{"type" => "string", "description" => "The content to write."}
        },
        "required" => ["path", "content"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path, "content" => content} = args, _abort_ref, _on_update) do
    cwd = Map.fetch!(args, "_cwd")

    case PathGuard.resolve_or_error(path, cwd) do
      {:error, %Result{} = r} -> {:ok, r}
      {:ok, abs_path} -> FileMutex.with_lock(abs_path, fn -> do_write(abs_path, content) end)
    end
  end

  defp do_write(abs_path, content) do
    with :ok <- File.mkdir_p(Path.dirname(abs_path)),
         :ok <- File.write(abs_path, content) do
      {:ok,
       %Result{
         content: [%Content.Text{text: "wrote #{byte_size(content)} bytes to #{abs_path}"}],
         details: %{path: abs_path, bytes: byte_size(content)}
       }}
    else
      {:error, reason} ->
        {:ok,
         %Result{
           content: [%Content.Text{text: "write failed: #{inspect(reason)} (#{abs_path})"}],
           is_error?: true
         }}
    end
  end
end
