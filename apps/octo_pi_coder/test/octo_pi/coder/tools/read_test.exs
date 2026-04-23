defmodule OctoPi.Coder.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.Read

  setup do
    tmp = Path.join(System.tmp_dir!(), "read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    ref = AbortRef.new()

    on_exit(fn ->
      File.rm_rf!(tmp)
      AbortRef.forget(ref)
    end)

    {:ok, tmp: tmp, ref: ref}
  end

  defp exec(args, ref, cwd),
    do: Read.execute("call_1", Map.put(args, "_cwd", cwd), ref, fn _ -> :ok end)

  test "reads full file", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "hello.txt")
    File.write!(path, "line1\nline2\nline3\n")

    assert {:ok, %Result{content: [%Content.Text{text: text}], is_error?: false}} =
             exec(%{"path" => path}, ref, tmp)

    assert text == "line1\nline2\nline3\n"
  end

  test "honors offset and limit", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "range.txt")
    File.write!(path, Enum.map_join(1..10, "", &"line#{&1}\n"))

    assert {:ok, %Result{content: [%Content.Text{text: text}]}} =
             exec(%{"path" => path, "offset" => 3, "limit" => 2}, ref, tmp)

    # Slice yields the two requested lines; trailing newline is
    # dropped along with the empty element from String.split.
    assert text == "line3\nline4"
  end

  test "truncates files over max line count", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "huge.txt")
    File.write!(path, Enum.map_join(1..15_000, "", &"x#{&1}\n"))

    assert {:ok, %Result{content: [%Content.Text{text: text}], details: details}} =
             exec(%{"path" => path}, ref, tmp)

    assert details.truncated == true
    assert details.truncated_by == :lines
    assert details.total_lines == 15_000
    line_count = text |> String.split("\n", trim: true) |> length()
    assert line_count <= 10_000
  end

  test "returns error tool-result for missing file", %{tmp: tmp, ref: ref} do
    path = Path.join(tmp, "nope.txt")

    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(%{"path" => path}, ref, tmp)

    assert msg =~ "enoent" or msg =~ "no such file"
  end

  test "rejects directories", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(%{"path" => tmp}, ref, tmp)

    assert msg =~ "directory"
  end

  test "rejects paths that escape session cwd", %{tmp: tmp, ref: ref} do
    assert {:ok, %Result{is_error?: true, content: [%Content.Text{text: msg}]}} =
             exec(%{"path" => "/etc/passwd"}, ref, tmp)

    assert msg =~ "escapes session cwd"
  end

  describe "line counting" do
    test "file ending with a newline: total_lines matches actual line count",
         %{tmp: tmp, ref: ref} do
      path = Path.join(tmp, "trailing_nl.txt")
      File.write!(path, "a\nb\nc\n")

      assert {:ok, %Result{details: %{total_lines: 3, output_lines: 3}}} =
               exec(%{"path" => path}, ref, tmp)
    end

    test "file without trailing newline: total_lines matches actual line count",
         %{tmp: tmp, ref: ref} do
      path = Path.join(tmp, "no_trailing.txt")
      File.write!(path, "a\nb")

      assert {:ok, %Result{details: %{total_lines: 2, output_lines: 2}}} =
               exec(%{"path" => path}, ref, tmp)
    end

    test "single line without newline: total_lines is 1", %{tmp: tmp, ref: ref} do
      path = Path.join(tmp, "single.txt")
      File.write!(path, "only")

      assert {:ok, %Result{details: %{total_lines: 1}}} =
               exec(%{"path" => path}, ref, tmp)
    end

    test "empty file: total_lines is 0", %{tmp: tmp, ref: ref} do
      path = Path.join(tmp, "empty.txt")
      File.write!(path, "")

      assert {:ok, %Result{details: %{total_lines: 0}}} =
               exec(%{"path" => path}, ref, tmp)
    end
  end
end
