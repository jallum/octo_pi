defmodule OctoPi.Coder.Tools.FindTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Find

  setup do
    tmp = Path.join(System.tmp_dir!(), "find-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sub"))
    File.write!(Path.join(tmp, "a.txt"), "1")
    File.write!(Path.join(tmp, "b.md"), "2")
    File.write!(Path.join([tmp, "sub", "c.txt"]), "3")

    ref = AbortRef.new()

    on_exit(fn ->
      File.rm_rf!(tmp)
      AbortRef.forget(ref)
    end)

    {:ok, tmp: tmp, ref: ref}
  end

  defp exec(args, ref, cwd),
    do: Find.execute("id", Map.put(args, "_cwd", cwd), ref, fn _ -> :ok end)

  test "glob matches files recursively", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"pattern" => "**/*.txt", "path" => tmp}, ref, tmp)

    assert text =~ "a.txt"
    assert text =~ "c.txt"
    refute text =~ "b.md"
  end

  test "no matches yields a note", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"pattern" => "**/*.zzz", "path" => tmp}, ref, tmp)

    assert text =~ "no matches" or text == ""
  end
end
