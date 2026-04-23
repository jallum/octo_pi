defmodule OctoPi.AI.Content.Image do
  @moduledoc """
  An image content block carrying base64-encoded data and a MIME type.
  """

  @enforce_keys [:data, :mime_type]
  @type t :: %__MODULE__{
          data: String.t(),
          mime_type: String.t()
        }

  defstruct [:data, :mime_type]
end
