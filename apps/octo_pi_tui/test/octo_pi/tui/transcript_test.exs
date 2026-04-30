defmodule OctoPi.TUI.TranscriptTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Transcript

  defmodule StubRenderer do
    @moduledoc """
    Test renderer that records every callback hit on a per-state
    counter. `to_iolist` emits a sentinel string carrying the
    current `entry`, `theme`, and `width` so tests can prove cache
    hits and resize correctness by string comparison.
    """
    @behaviour Transcript.Renderer

    defstruct [:entry, finalized?: false, calls: %{new: 0, put: 0, finalize: 0, to_iolist: 0}]

    @impl true
    def new(entry), do: %__MODULE__{entry: entry, calls: bump(%{new: 0, put: 0, finalize: 0, to_iolist: 0}, :new)}

    @impl true
    def put(%__MODULE__{} = s, entry), do: %{s | entry: entry, calls: bump(s.calls, :put)}

    @impl true
    def finalize(%__MODULE__{} = s, entry),
      do: %{s | entry: entry, finalized?: true, calls: bump(s.calls, :finalize)}

    @impl true
    def to_iolist(%__MODULE__{entry: entry}, theme, width),
      do: "[#{inspect(entry)}|#{inspect(theme)}|#{width}]"

    defp bump(map, key), do: Map.update(map, key, 1, &(&1 + 1))
  end

  describe "new/0" do
    test "starts empty" do
      t = Transcript.new()
      assert t.order == []
      assert t.data == %{}
      assert t.renderers == %{}
      assert t.rendered == %{}
      assert MapSet.size(t.finalized) == 0
    end
  end

  describe "append/4" do
    test "adds entry, fresh renderer, empty rendered slot" do
      t = Transcript.new() |> Transcript.append(:a, "alpha", StubRenderer)

      assert t.order == [:a]
      assert t.data == %{a: "alpha"}
      assert match?(%StubRenderer{entry: "alpha"}, t.renderers[:a])
      assert t.rendered == %{}
    end

    test "newest entries land at head; render emits oldest-first" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "alpha", StubRenderer)
        |> Transcript.append(:b, "beta", StubRenderer)
        |> Transcript.append(:c, "gamma", StubRenderer)

      assert t.order == [:c, :b, :a]

      {io, _} = Transcript.render(t, :dark, 80)
      flat = IO.iodata_to_binary(io)

      assert flat =~ ~r/alpha.*beta.*gamma/s
    end
  end

  describe "update/3" do
    test "feeds chunk to the renderer; data is replaced" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "he", StubRenderer)
        |> Transcript.update(:a, "hello")

      assert t.data[:a] == "hello"
      assert t.renderers[:a].entry == "hello"
      assert t.renderers[:a].calls.put == 1
    end
  end

  describe "finalize/3" do
    test "marks entry finalized; renderer state flips" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "hi", StubRenderer)
        |> Transcript.finalize(:a, "hi")

      assert MapSet.member?(t.finalized, :a)
      assert t.renderers[:a].finalized?
    end

    test "first render after finalize materializes into rendered and drops the renderer" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "hi", StubRenderer)
        |> Transcript.finalize(:a, "hi")

      {_, t} = Transcript.render(t, :dark, 80)

      assert Map.has_key?(t.rendered, :a)
      refute Map.has_key?(t.renderers, :a)
    end
  end

  describe "render/3" do
    test "returns oldest-first iodata tree across all entries" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "one", StubRenderer)
        |> Transcript.append(:b, "two", StubRenderer)

      {io, _} = Transcript.render(t, :dark, 80)
      flat = IO.iodata_to_binary(io)
      assert flat == "[\"one\"|:dark|80][\"two\"|:dark|80]"
    end

    test "second render after finalize is a cache hit (renderer never re-called)" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "hi", StubRenderer)
        |> Transcript.finalize(:a, "hi")

      {_, t1} = Transcript.render(t, :dark, 80)
      cached = Map.fetch!(t1.rendered, :a)

      # Mutate the rendered cache to a sentinel; if render reads from
      # the cache (not the renderer, which has been dropped), the
      # second render emits the sentinel.
      t2 = put_in(t1.rendered[:a], "SENTINEL")
      {io, _} = Transcript.render(t2, :dark, 80)
      assert IO.iodata_to_binary(io) == "SENTINEL"

      # And the original cached output really came from the renderer.
      assert IO.iodata_to_binary(cached) == "[\"hi\"|:dark|80]"
    end

    test "streaming entry stays in renderers across renders" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "h", StubRenderer)

      {_, t} = Transcript.render(t, :dark, 80)
      assert Map.has_key?(t.renderers, :a)

      t = Transcript.update(t, :a, "hi")
      {_, t} = Transcript.render(t, :dark, 80)
      assert Map.has_key?(t.renderers, :a)
      assert IO.iodata_to_binary(Map.fetch!(t.rendered, :a)) =~ "hi"
    end
  end

  describe "resize/3" do
    test "rebuilds renderers from data; renders at new width" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "alpha", StubRenderer)
        |> Transcript.update(:a, "alpha2")
        |> Transcript.finalize(:a, "alpha2")

      {_, t} = Transcript.render(t, :dark, 80)
      assert IO.iodata_to_binary(t.rendered[:a]) =~ "|80]"

      t2 = Transcript.resize(t, :light, 40)

      assert IO.iodata_to_binary(t2.rendered[:a]) == "[\"alpha2\"|:light|40]"
      # finalized id stays out of renderers after resize+render.
      refute Map.has_key?(t2.renderers, :a)
    end

    test "preserves order across resize" do
      t =
        Transcript.new()
        |> Transcript.append(:a, "1", StubRenderer)
        |> Transcript.append(:b, "2", StubRenderer)
        |> Transcript.append(:c, "3", StubRenderer)

      t = Transcript.resize(t, :dark, 80)
      {io, _} = Transcript.render(t, :dark, 80)
      flat = IO.iodata_to_binary(io)
      assert flat == "[\"1\"|:dark|80][\"2\"|:dark|80][\"3\"|:dark|80]"
    end
  end

  describe "byte equality with from-scratch rebuild" do
    test "append/update/finalize/render produces same bytes as a fresh rebuild" do
      live =
        Transcript.new()
        |> Transcript.append(:a, "h", StubRenderer)
        |> Transcript.update(:a, "he")
        |> Transcript.update(:a, "hel")
        |> Transcript.update(:a, "hello")
        |> Transcript.finalize(:a, "hello")
        |> Transcript.append(:b, "w", StubRenderer)
        |> Transcript.update(:b, "world")
        |> Transcript.finalize(:b, "world")

      fresh =
        Transcript.new()
        |> Transcript.append(:a, "hello", StubRenderer)
        |> Transcript.finalize(:a, "hello")
        |> Transcript.append(:b, "world", StubRenderer)
        |> Transcript.finalize(:b, "world")

      {io1, _} = Transcript.render(live, :dark, 80)
      {io2, _} = Transcript.render(fresh, :dark, 80)

      assert IO.iodata_to_binary(io1) == IO.iodata_to_binary(io2)
    end
  end
end
