defmodule OctoPi.Coder.Tools.EditTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Edit

  setup do
    tmp = Path.join(System.tmp_dir!(), "edit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    ref = AbortRef.new()

    on_exit(fn ->
      File.rm_rf!(tmp)
      AbortRef.forget(ref)
    end)

    {:ok, tmp: tmp, ref: ref}
  end

  defp exec(args, ref, cwd), do: Edit.execute("call_1", Map.put(args, "_cwd", cwd), ref, fn _ -> :ok end)

  test "replaces a single occurrence", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "code.ex")
    File.write!(path, "def foo, do: :bar")

    assert {:ok, %Result{is_error?: false}} =
             exec(
               %{
                 "path" => path,
                 "edits" => [%{"old_text" => ":bar", "new_text" => ":baz"}]
               },
               ref,
               tmp
             )

    assert File.read!(path) == "def foo, do: :baz"
  end

  test "fails when old_text not found", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "f.txt")
    File.write!(path, "abc")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(
               %{"path" => path, "edits" => [%{"old_text" => "xyz", "new_text" => "q"}]},
               ref,
               tmp
             )

    assert msg =~ "not found"
    assert File.read!(path) == "abc"
  end

  test "fails when old_text is not unique", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "dup.txt")
    File.write!(path, "cat\ncat\n")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(
               %{"path" => path, "edits" => [%{"old_text" => "cat", "new_text" => "dog"}]},
               ref,
               tmp
             )

    assert msg =~ "multiple"
    assert File.read!(path) == "cat\ncat\n"
  end

  test "multiple disjoint edits in one call", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "multi.ex")
    File.write!(path, "def foo, do: :a\ndef bar, do: :b\n")

    assert {:ok, %Result{is_error?: false, details: %{replacements: 2}}} =
             exec(
               %{
                 "path" => path,
                 "edits" => [
                   %{"old_text" => ":a", "new_text" => ":x"},
                   %{"old_text" => ":b", "new_text" => ":y"}
                 ]
               },
               ref,
               tmp
             )

    assert File.read!(path) == "def foo, do: :x\ndef bar, do: :y\n"
  end

  test "overlapping edits are rejected", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "overlap.txt")
    File.write!(path, "abcdef")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(
               %{
                 "path" => path,
                 "edits" => [
                   %{"old_text" => "abcd", "new_text" => "XY"},
                   %{"old_text" => "cdef", "new_text" => "ZW"}
                 ]
               },
               ref,
               tmp
             )

    assert msg =~ "overlap"
    assert File.read!(path) == "abcdef"
  end

  test "missing file yields an error", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "none.txt")

    assert {:ok, %Result{is_error?: true}} =
             exec(
               %{"path" => path, "edits" => [%{"old_text" => "x", "new_text" => "y"}]},
               ref,
               tmp
             )
  end
end
