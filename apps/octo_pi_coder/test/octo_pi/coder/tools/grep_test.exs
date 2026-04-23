defmodule OctoPi.Coder.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Grep

  setup do
    tmp = Path.join(System.tmp_dir!(), "grep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "a.txt"), "alpha\nbeta\ngamma\n")
    File.write!(Path.join(tmp, "b.txt"), "BETA is loud\n")

    ref = AbortRef.new()

    on_exit(fn ->
      File.rm_rf!(tmp)
      AbortRef.forget(ref)
    end)

    {:ok, tmp: tmp, ref: ref}
  end

  defp exec(args, ref), do: Grep.execute("id", args, ref, fn _ -> :ok end)

  test "finds a literal pattern", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"pattern" => "beta", "path" => tmp}, ref)

    assert text =~ "a.txt"
    assert text =~ "beta"
  end

  test "case-insensitive search catches both cases", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{content: [%Content.Text{text: text}]}} =
             exec(%{"pattern" => "beta", "path" => tmp, "case_insensitive" => true}, ref)

    assert text =~ "a.txt"
    assert text =~ "b.txt"
  end

  test "no matches yields a note, not an error", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"pattern" => "nothing_here", "path" => tmp}, ref)

    assert text =~ "no matches" or text == ""
  end
end
