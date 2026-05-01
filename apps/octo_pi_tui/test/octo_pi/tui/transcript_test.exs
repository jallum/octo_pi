defmodule OctoPi.TUI.TranscriptTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Transcript

  defmodule StubRenderer do
    @moduledoc """
    Test renderer that bakes the entry + ctx into its state at
    `new/2`. `to_iolist/1` emits a sentinel string carrying both
    so tests can prove cache hits and ctx propagation by string
    comparison.
    """
    @behaviour Transcript.Renderer

    defstruct [:entry, :ctx, finalized?: false]

    @impl true
    def new(entry, ctx), do: %__MODULE__{entry: entry, ctx: ctx}

    @impl true
    def put(%__MODULE__{} = s, entry), do: %{s | entry: entry}

    @impl true
    def finalize(%__MODULE__{} = s, entry), do: %{s | entry: entry, finalized?: true}

    @impl true
    def to_iolist(%__MODULE__{entry: entry, ctx: ctx}),
      do: "[#{inspect(entry)}|#{inspect(ctx)}]"
  end

  describe "new/1" do
    test "starts empty with nil ctx by default" do
      t = Transcript.new()
      assert t.order == []
      assert t.entries == %{}
      assert t.entries == %{}
      assert t.rendered == %{}
      assert t.ctx == nil
      assert MapSet.size(t.streaming) == 0
    end

    test "stamps the given ctx" do
      t = Transcript.new(%{theme: :dark, width: 80})
      assert t.ctx == %{theme: :dark, width: 80}
    end
  end

  describe "append/4" do
    test "uses the stored ctx for Renderer.new" do
      t =
        Transcript.new(%{theme: :dark, width: 80})
        |> Transcript.append(:a, "alpha", StubRenderer)

      assert t.entries[:a].renderer.ctx == %{theme: :dark, width: 80}
    end

    test "newest entries land at head; render emits oldest-first" do
      t =
        Transcript.new(:ctx)
        |> Transcript.append(:a, "alpha", StubRenderer)
        |> Transcript.append(:b, "beta", StubRenderer)
        |> Transcript.append(:c, "gamma", StubRenderer)

      assert t.order == [:c, :b, :a]

      {io, _} = Transcript.render(t)
      flat = IO.iodata_to_binary(io)
      assert flat =~ ~r/alpha.*beta.*gamma/s
    end
  end

  describe "update/3 / finalize/3" do
    test "update feeds chunk to the renderer; data is replaced" do
      t =
        Transcript.new(:ctx)
        |> Transcript.append(:a, "he", StubRenderer)
        |> Transcript.update(:a, "hello")

      assert t.entries[:a].data == "hello"
      assert t.entries[:a].renderer.entry == "hello"
    end

    test "finalize marks entry; first render after that drops the renderer" do
      t =
        Transcript.new(:ctx)
        |> Transcript.append(:a, "hi", StubRenderer)
        |> Transcript.finalize(:a, "hi")

      refute MapSet.member?(t.streaming, :a)

      {_, t} = Transcript.render(t)
      assert Map.has_key?(t.rendered, :a)
      assert t.entries[:a].renderer == nil
    end
  end

  describe "render/2 — cache + ctx propagation" do
    test "second render after finalize is a cache hit (renderer dropped)" do
      t =
        Transcript.new(:ctx)
        |> Transcript.append(:a, "hi", StubRenderer)
        |> Transcript.finalize(:a, "hi")

      {_, t1} = Transcript.render(t)
      cached = Map.fetch!(t1.rendered, :a)

      # Mutate the cache to a sentinel; if render reads from cache
      # (renderer is dropped), second render emits the sentinel.
      t2 = put_in(t1.rendered[:a], "SENTINEL")
      {io, _} = Transcript.render(t2)
      assert IO.iodata_to_binary(io) == "SENTINEL"
      assert IO.iodata_to_binary(cached) =~ "hi"
    end

    test "passing a different ctx triggers resize: renderers rebuilt with new ctx" do
      t =
        Transcript.new(%{theme: :dark, width: 80})
        |> Transcript.append(:a, "alpha", StubRenderer)
        |> Transcript.finalize(:a, "alpha")

      {_, t} = Transcript.render(t)
      assert IO.iodata_to_binary(t.rendered[:a]) =~ "width: 80"

      {_, t2} = Transcript.render(t, %{theme: :light, width: 40})
      flat = IO.iodata_to_binary(t2.rendered[:a])
      assert flat =~ "alpha"
      assert flat =~ "theme: :light"
      assert flat =~ "width: 40"

      assert t2.ctx == %{theme: :light, width: 40}
      # Finalized id stays out of renderers after resize+render.
      assert t2.entries[:a].renderer == nil
    end

    test "passing the same ctx does not rebuild renderers" do
      t =
        Transcript.new(%{theme: :dark, width: 80})
        |> Transcript.append(:a, "alpha", StubRenderer)

      r_before = t.entries[:a].renderer
      {_, t2} = Transcript.render(t, %{theme: :dark, width: 80})

      assert t2.entries[:a].renderer === r_before, "no rebuild when ctx is unchanged"
    end
  end

  describe "resize/2" do
    test "rebuilds every renderer with the new ctx, replaying finalize for finalized" do
      t =
        Transcript.new(%{theme: :dark, width: 80})
        |> Transcript.append(:a, "x", StubRenderer)
        |> Transcript.finalize(:a, "x")
        |> Transcript.append(:b, "y", StubRenderer)

      t2 = Transcript.resize(t, %{theme: :light, width: 100})

      assert t2.ctx == %{theme: :light, width: 100}
      assert t2.entries[:a].renderer.ctx == %{theme: :light, width: 100}
      assert t2.entries[:a].renderer.finalized?, "finalize replayed for :a"
      assert t2.entries[:b].renderer.ctx == %{theme: :light, width: 100}
      refute t2.entries[:b].renderer.finalized?
      assert t2.rendered == %{}
    end
  end

  describe "byte equality with from-scratch rebuild" do
    test "append/update/finalize/render produces same bytes as a fresh build" do
      live =
        Transcript.new(:ctx)
        |> Transcript.append(:a, "h", StubRenderer)
        |> Transcript.update(:a, "he")
        |> Transcript.update(:a, "hello")
        |> Transcript.finalize(:a, "hello")
        |> Transcript.append(:b, "w", StubRenderer)
        |> Transcript.update(:b, "world")
        |> Transcript.finalize(:b, "world")

      fresh =
        Transcript.new(:ctx)
        |> Transcript.append(:a, "hello", StubRenderer)
        |> Transcript.finalize(:a, "hello")
        |> Transcript.append(:b, "world", StubRenderer)
        |> Transcript.finalize(:b, "world")

      {io1, _} = Transcript.render(live)
      {io2, _} = Transcript.render(fresh)

      assert IO.iodata_to_binary(io1) == IO.iodata_to_binary(io2)
    end
  end
end
