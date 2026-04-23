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

  @doc "Build a `%Tool{}` registered under the agent."
  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "write",
      label: "Write file",
      description: "Write content to a file, creating parent directories as needed.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute path to the file."},
          "content" => %{"type" => "string", "description" => "The content to write."}
        },
        "required" => ["path", "content"]
      },
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path, "content" => content}, _abort_ref, _on_update) do
    FileMutex.with_lock(path, fn ->
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content) do
        {:ok,
         %Result{
           content: [%Content.Text{text: "wrote #{byte_size(content)} bytes to #{path}"}],
           details: %{path: path, bytes: byte_size(content)}
         }}
      else
        {:error, reason} ->
          {:ok,
           %Result{
             content: [%Content.Text{text: "write failed: #{inspect(reason)} (#{path})"}],
             is_error?: true
           }}
      end
    end)
  end
end
