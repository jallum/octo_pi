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
