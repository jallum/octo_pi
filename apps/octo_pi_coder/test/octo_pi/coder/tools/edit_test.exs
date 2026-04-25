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
                 "old_string" => ":bar",
                 "new_string" => ":baz"
               },
               ref,
               tmp
             )

    assert File.read!(path) == "def foo, do: :baz"
  end

  test "fails when old_string not found", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "f.txt")
    File.write!(path, "abc")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(%{"path" => path, "old_string" => "xyz", "new_string" => "q"}, ref, tmp)

    assert msg =~ "not found"
    assert File.read!(path) == "abc"
  end

  test "fails when old_string is not unique and replace_all is false", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "dup.txt")
    File.write!(path, "cat\ncat\n")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(%{"path" => path, "old_string" => "cat", "new_string" => "dog"}, ref, tmp)

    assert msg =~ "multiple"
    assert File.read!(path) == "cat\ncat\n"
  end

  test "replace_all replaces every occurrence", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "multi.txt")
    File.write!(path, "cat\ncat\ncat\n")

    assert {:ok, %Result{is_error?: false}} =
             exec(
               %{
                 "path" => path,
                 "old_string" => "cat",
                 "new_string" => "dog",
                 "replace_all" => true
               },
               ref,
               tmp
             )

    assert File.read!(path) == "dog\ndog\ndog\n"
  end

  test "missing file yields an error", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "none.txt")

    assert {:ok, %Result{is_error?: true}} =
             exec(%{"path" => path, "old_string" => "x", "new_string" => "y"}, ref, tmp)
  end
end
