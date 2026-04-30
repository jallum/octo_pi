defmodule OctoPi.Coder.Tools.LsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Ls

  setup do
    tmp = Path.join(System.tmp_dir!(), "ls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    ref = AbortRef.new()

    on_exit(fn ->
      File.rm_rf!(tmp)
      AbortRef.forget(ref)
    end)

    {:ok, tmp: tmp, ref: ref}
  end

  defp exec(args, ref, cwd), do: Ls.execute("call_1", Map.put(args, "_cwd", cwd), ref, fn _ -> :ok end)

  test "missing :path defaults to current directory", %{tmp: tmp, ref: ref} do
    File.write!(Path.join(tmp, "a.txt"), "hi")
    cwd = File.cwd!()

    try do
      File.cd!(tmp)
      assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} = exec(%{}, ref, tmp)
      assert text =~ "a.txt"
    after
      File.cd!(cwd)
    end
  end

  test "lists files and dirs in a directory", %{tmp: tmp, ref: ref} do
    File.write!(Path.join(tmp, "a.txt"), "hi")
    File.mkdir_p!(Path.join(tmp, "sub"))

    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"path" => tmp}, ref, tmp)

    assert text =~ "a.txt"
    assert text =~ "sub"
  end

  test "empty directory returns a note", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"path" => tmp}, ref, tmp)

    assert text =~ "empty" or text == ""
  end

  test "non-existent path yields an error", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{is_error?: true}} =
             exec(%{"path" => Path.join(tmp, "nope")}, ref, tmp)
  end

  test "path that is a file (not a dir) yields an error", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "not-a-dir.txt")
    File.write!(path, "x")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(%{"path" => path}, ref, tmp)

    assert msg =~ "directory" or msg =~ "not a dir"
  end
end
