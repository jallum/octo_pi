defmodule OctoPi.TUI.TranscriptStubStatic do
  @moduledoc """
  Test entry that renders one line carrying its snapshot + a
  fingerprint of the live ctx. Static (returns `nil` cadence).
  Tests can prove ctx propagation by string comparison.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.VDOM

  defstruct [:snapshot]

  @impl true
  def render(%__MODULE__{snapshot: s} = self, ctx) do
    {self, %VDOM.VLines{lines: ["[#{inspect(s)}|#{inspect(ctx.theme.name)}|w=#{ctx.width}]"]}}
  end
end

defmodule OctoPi.TUI.TranscriptStubStreaming do
  @moduledoc """
  Streaming test entry. `update/2` and `finalize/2` evolve the
  snapshot. `render/2` emits the snapshot plus the live ctx fingerprint.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.VDOM

  defstruct snapshot: "", finalized?: false

  @impl true
  def update(%__MODULE__{} = self, snapshot), do: %{self | snapshot: snapshot}

  @impl true
  def finalize(%__MODULE__{} = self, snapshot), do: %{self | snapshot: snapshot, finalized?: true}

  @impl true
  def render(%__MODULE__{snapshot: s} = self, ctx) do
    {self, %VDOM.VLines{lines: ["[stream:#{inspect(s)}|#{inspect(ctx.theme.name)}|w=#{ctx.width}]"]}}
  end
end
