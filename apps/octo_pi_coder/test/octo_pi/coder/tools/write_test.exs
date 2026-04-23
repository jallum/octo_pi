defmodule OctoPi.Coder.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Write

  setup do
    tmp = Path.join(System.tmp_dir!(), "write-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    ref = AbortRef.new()

    on_exit(fn ->
      File.rm_rf!(tmp)
      AbortRef.forget(ref)
    end)

    {:ok, tmp: tmp, ref: ref}
  end

  defp exec(args, ref, cwd),
    do: Write.execute("call_1", Map.put(args, "_cwd", cwd), ref, fn _ -> :ok end)

  test "writes a new file", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "new.txt")

    assert {:ok, %Result{content: [%Content.Text{text: msg}], is_error?: false}} =
             exec(%{"path" => path, "content" => "hello world"}, ref, tmp)

    assert msg =~ "wrote"
    assert File.read!(path) == "hello world"
  end

  test "creates intermediate directories", %{tmp: tmp, ref: ref} do
    path = Path.join([tmp, "a", "b", "c.txt"])

    assert {:ok, %Result{is_error?: false}} =
             exec(%{"path" => path, "content" => "nested"}, ref, tmp)

    assert File.read!(path) == "nested"
  end

  test "overwrites existing file", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "existing.txt")
    File.write!(path, "original")

    assert {:ok, %Result{is_error?: false}} =
             exec(%{"path" => path, "content" => "replaced"}, ref, tmp)

    assert File.read!(path) == "replaced"
  end
end
