defmodule OctoPi.TUI.VDOM do
  @moduledoc """
  VNode type definitions for the React-style virtual DOM.

  A VNode is an immutable struct that represents a region of the UI.
  The painter walks a tree of VNodes once, writing into a LineBuf.
  No `++`, no `flat_map`, no `List.flatten` in the hot path.

  VNode types:

    * %VText{text, width} — scalar string with cached visible width.
    * %VLines{lines} — already-materialized list of binaries (escaped via Compat).
    * %VFlow{children} — vertical stack; children is iodata (scalar or nested list).
    * %VRow{children} — horizontal row; children may include VZone nodes.
    * %VBox{border?, padding_x, padding_y, children} — bordered box with padding.
    * %VZone{type, id, children} — OSC 133 zone welding; type ∈ [:prompt, :output, :command].
    * %VMemo{key, thunk, cell} — memoization cell; thunk returns a VNode or list.
    * %VHole{slot_id} — placeholder for transcript/Interactive extensibility.
    * %VCursor{} — zero-width leaf marking cursor position.
  """

  defmodule VText do
    @moduledoc "Scalar text node with cached visible width."
    defstruct [:text, :width]

    @type t :: %__MODULE__{
            text: String.t(),
            width: non_neg_integer()
          }
  end

  defmodule VLines do
    @moduledoc "Materialized line list (escaped via Compat adapter)."
    defstruct [:lines]

    @type t :: %__MODULE__{
            lines: [String.t()]
          }
  end

  defmodule VFlow do
    @moduledoc "Vertical flow container; children is iodata."
    defstruct [:children]

    @type children() :: t() | [children()] | iodata()
    @type t :: %__MODULE__{
            children: children()
          }
  end

  defmodule VRow do
    @moduledoc "Horizontal row; children is iodata."
    defstruct [:children]

    @type children() :: t() | [children()] | iodata()
    @type t :: %__MODULE__{
            children: children()
          }
  end

  defmodule VBox do
    @moduledoc "Box with optional border and padding."
    defstruct [:border?, :padding_x, :padding_y, :children]

    @type t :: %__MODULE__{
            border?: boolean(),
            padding_x: non_neg_integer(),
            padding_y: non_neg_integer(),
            children: VFlow.children()
          }
  end

  defmodule VZone do
    @moduledoc "OSC 133 zone for shell integration."
    defstruct [:type, :id, :children]

    @type zone_type :: :prompt | :output | :command
    @type t :: %__MODULE__{
            type: zone_type(),
            id: String.t(),
            children: VFlow.children()
          }
  end

  defmodule VMemo do
    @moduledoc """
    Memoization cell.

    - key: unique key within parent scope
    - thunk: 0-arg function returning a VNode or list (iodata rules apply)
    - cell: reconciler-owned storage; opaque to paint code
    """
    defstruct [:key, :thunk, :cell]

    @type t :: %__MODULE__{
            key: term(),
            thunk: (-> VFlow.children()),
            cell: reference() | nil
          }
  end

  defmodule VHole do
    @moduledoc "Placeholder for Interactive extensibility."
    defstruct [:slot_id]

    @type t :: %__MODULE__{
            slot_id: term()
          }
  end

  defmodule VCursor do
    @moduledoc "Zero-width leaf marking cursor position."
    defstruct [:style]

    @type t :: %__MODULE__{style: :bar | :block | :underline}
  end

  @type t ::
          VText.t()
          | VLines.t()
          | VFlow.t()
          | VRow.t()
          | VBox.t()
          | VZone.t()
          | VMemo.t()
          | VHole.t()
          | VCursor.t()

  defguard is_vnode(term)
           when is_struct(term, VText) or
                  is_struct(term, VLines) or
                  is_struct(term, VFlow) or
                  is_struct(term, VRow) or
                  is_struct(term, VBox) or
                  is_struct(term, VZone) or
                  is_struct(term, VMemo) or
                  is_struct(term, VHole) or
                  is_struct(term, VCursor)

  @doc "Returns true if term is a VNode struct."
  @spec vnode_term?(term()) :: boolean()
  def vnode_term?(term), do: is_vnode(term)
end
