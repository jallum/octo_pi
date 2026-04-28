defmodule OctoPi.TUI.Clipboard do
  @moduledoc false

  @spec osc52(String.t()) :: String.t()
  def osc52(text) do
    encoded = Base.encode64(text)
    "\e]52;c;#{encoded}\a"
  end

  @spec copy(String.t(), keyword()) :: {atom(), String.t()}
  def copy(text, opts \\ []) do
    osc = osc52(text)

    if Keyword.get(opts, :write_osc) != false do
      IO.write(osc)
    end

    try_native(text)
    {:ok, osc}
  end

  @spec paste_image_from_clipboard() :: {:ok, %{data: binary(), mime_type: String.t()}} | :error
  def paste_image_from_clipboard do
    case :os.type() do
      {:unix, :darwin} -> paste_macos()
      {:unix, _} -> paste_linux()
      _ -> :error
    end
  end

  @spec platform_command() :: {String.t(), [String.t()]} | nil
  def platform_command do
    case :os.type() do
      {:unix, :darwin} -> {"pbcopy", []}
      {:unix, _} -> detect_linux_clipboard()
      _ -> nil
    end
  end

  @spec extract_code_blocks(String.t()) :: [String.t()]
  def extract_code_blocks(text) do
    ~r/```[^\n]*\n(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> String.trim(block) end)
  end

  defp try_native(text) do
    case platform_command() do
      {cmd, args} ->
        port = Port.open({:spawn_executable, System.find_executable(cmd)}, [:binary, args: args])
        Port.command(port, text)
        Port.close(port)

      nil ->
        :noop
    end
  rescue
    _ -> :noop
  end

  defp paste_macos do
    if System.find_executable("pngpaste") do
      paste_via_cmd("pngpaste", ["-"])
    else
      paste_macos_osascript()
    end
  rescue
    _ -> :error
  end

  defp paste_macos_osascript do
    case System.cmd("osascript", ["-e", "the clipboard as «class PNGf»"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/«data PNGf([0-9A-Fa-f]+)»/, String.trim(output)) do
          [_, hex] -> decode_hex_png(hex)
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp decode_hex_png(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, data} -> {:ok, %{data: Base.encode64(data), mime_type: "image/png"}}
      _ -> :error
    end
  end

  defp paste_linux do
    cond do
      System.get_env("WAYLAND_DISPLAY") && System.find_executable("wl-paste") ->
        paste_via_cmd("wl-paste", ["--type", "image/png"])

      System.get_env("DISPLAY") && System.find_executable("xclip") ->
        paste_via_cmd("xclip", ["-selection", "clipboard", "-t", "image/png", "-o"])

      true ->
        :error
    end
  end

  defp paste_via_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {data, 0} when byte_size(data) > 0 ->
        {:ok, %{data: Base.encode64(data), mime_type: "image/png"}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp detect_linux_clipboard do
    cond do
      System.get_env("WAYLAND_DISPLAY") && System.find_executable("wl-copy") ->
        {"wl-copy", []}

      System.get_env("DISPLAY") && System.find_executable("xclip") ->
        {"xclip", ["-selection", "clipboard"]}

      System.get_env("DISPLAY") && System.find_executable("xsel") ->
        {"xsel", ["--clipboard", "--input"]}

      true ->
        nil
    end
  end
end
