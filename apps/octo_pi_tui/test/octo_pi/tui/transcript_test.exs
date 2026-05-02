defmodule OctoPi.TUI.TranscriptTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.Transcript
  alias OctoPi.TUI.TranscriptStubStatic, as: Static
  alias OctoPi.TUI.TranscriptStubStreaming, as: Stream

  @theme Theme.load_builtin(:dark, :truecolor)

  defp ctx(opts \\ []) do
    struct!(RenderContext, Keyword.merge([theme: @theme, width: 80], opts))
  end

  defp flat(lines), do: Enum.join(lines, "\n")

  defp lines_only(slots) do
    alias OctoPi.TUI.VDOM

    Enum.flat_map(slots, fn
      {_, %VDOM.VLines{lines: lines}} -> lines
      {_, lines} when is_list(lines) -> lines
    end)
  end

  describe "new/0 + append/3" do
    test "starts empty" do
      t = Transcript.new()
      assert t.order == []
      assert t.data == %{}
      assert t.cache == %{}
      assert t.dirty == MapSet.new()
    end

    test "newest entries land at head; render emits oldest-first" do
      t =
        Transcript.new()
        |> Transcript.append(:a, %Static{snapshot: "alpha"})
        |> Transcript.append(:b, %Static{snapshot: "beta"})
        |> Transcript.append(:c, %Static{snapshot: "gamma"})

      assert t.order == [:c, :b, :a]
      {slots, _} = Transcript.render(t, ctx())
      assert flat(lines_only(slots)) =~ ~r/alpha.*beta.*gamma/s
    end

    test "appended slots start dirty (no cached lines yet)" do
      t = Transcript.append(Transcript.new(), :a, %Static{snapshot: "x"})
      assert MapSet.member?(t.dirty, :a)
      refute Map.has_key?(t.cache, :a)
    end
  end

  describe "render/2 caching" do
    test "after first render the slot is cached and clean" do
      t = Transcript.append(Transcript.new(), :a, %Static{snapshot: "alpha"})

      {slots, t} = Transcript.render(t, ctx())
      refute MapSet.member?(t.dirty, :a)
      assert Map.has_key?(t.cache, :a)
      assert flat(lines_only(slots)) =~ "alpha"
    end

    test "second render at the same ctx is a cache hit (component not called)" do
      t = Transcript.append(Transcript.new(), :a, %Static{snapshot: "alpha"})

      {_, t1} = Transcript.render(t, ctx())
      cached = Map.fetch!(t1.cache, :a)

      # Mutate the cache to a sentinel; if the second render reads
      # from cache, we'll see the sentinel rather than freshly built lines.
      t2 = put_in(t1.cache[:a], ["SENTINEL"])
      {slots, _} = Transcript.render(t2, ctx())

      assert flat(lines_only(slots)) == "SENTINEL"
      assert flat(lines_only([{nil, cached}])) =~ "alpha"
    end

    test "render threads the updated entry struct back into data" do
      t =
        Transcript.new()
        |> Transcript.append(:a, %Stream{snapshot: ""})
        |> Transcript.update(:a, "v1")

      {_, t1} = Transcript.render(t, ctx())
      assert t1.data[:a].snapshot == "v1"

      t1 = Transcript.update(t1, :a, "v2")
      {_, t2} = Transcript.render(t1, ctx())
      assert t2.data[:a].snapshot == "v2"
    end
  end

  describe "update/3 + finalize/3 (streaming)" do
    test "update marks the slot dirty so next render rebuilds" do
      t = Transcript.append(Transcript.new(), :a, %Stream{snapshot: ""})
      {_, t} = Transcript.render(t, ctx())
      refute MapSet.member?(t.dirty, :a)

      t = Transcript.update(t, :a, "hello")
      assert MapSet.member?(t.dirty, :a)
      assert t.data[:a].snapshot == "hello"
    end

    test "finalize marks the slot dirty AND sets finalized? on the struct" do
      t = Transcript.append(Transcript.new(), :a, %Stream{snapshot: ""})
      t = Transcript.finalize(t, :a, "done")
      assert MapSet.member?(t.dirty, :a)
      assert t.data[:a].snapshot == "done"
      assert t.data[:a].finalized?
    end

    test "update on a non-streaming entry raises" do
      t = Transcript.append(Transcript.new(), :a, %Static{snapshot: "x"})

      assert_raise ArgumentError, ~r/does not implement StreamingComponent/, fn ->
        Transcript.update(t, :a, "y")
      end
    end
  end

  describe "invalidate/1 — global cache bust (e.g. resize)" do
    test "marks every slot dirty" do
      t =
        Transcript.new()
        |> Transcript.append(:a, %Static{snapshot: "alpha"})
        |> Transcript.append(:b, %Static{snapshot: "beta"})

      {_, t} = Transcript.render(t, ctx())
      assert t.dirty == MapSet.new()

      t = Transcript.invalidate(t)
      assert t.dirty == MapSet.new([:a, :b])
    end
  end

  describe "byte equality across live and replayed builds" do
    test "append/update/finalize then render matches a fresh static build" do
      live =
        Transcript.new()
        |> Transcript.append(:a, %Stream{snapshot: ""})
        |> Transcript.update(:a, "he")
        |> Transcript.update(:a, "hello")
        |> Transcript.finalize(:a, "hello")
        |> Transcript.append(:b, %Stream{snapshot: ""})
        |> Transcript.update(:b, "world")
        |> Transcript.finalize(:b, "world")

      fresh =
        Transcript.new()
        |> Transcript.append(:a, %Stream{snapshot: "hello", finalized?: true})
        |> Transcript.append(:b, %Stream{snapshot: "world", finalized?: true})

      {p1, _} = Transcript.render(live, ctx())
      {p2, _} = Transcript.render(fresh, ctx())

      assert flat(lines_only(p1)) == flat(lines_only(p2))
    end
  end
end
