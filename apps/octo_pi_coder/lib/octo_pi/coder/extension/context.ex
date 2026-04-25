defmodule OctoPi.Coder.Extension.Context do
  @moduledoc false

  alias OctoPi.Agent.Message
  alias OctoPi.AI.Model

  @type t :: %__MODULE__{
          cwd: String.t(),
          model: term(),
          session_id: String.t() | nil,
          idle?: boolean(),
          signal: reference() | nil,
          has_ui?: boolean(),
          ui: OctoPi.Coder.Extension.UIContext.t() | nil,
          get_entries: (-> [Message.t()]),
          get_branch: (-> [Message.t()]),
          get_leaf_entry_id: (-> String.t() | nil),
          find_model: (atom(), String.t() -> Model.t() | nil),
          get_model_auth: (Model.t() -> {:ok, map()} | {:error, String.t()})
        }

  defstruct cwd: ".",
            model: nil,
            session_id: nil,
            idle?: false,
            signal: nil,
            has_ui?: false,
            ui: nil,
            get_entries: &__MODULE__.empty_entries/0,
            get_branch: &__MODULE__.empty_entries/0,
            get_leaf_entry_id: &__MODULE__.nil_entry_id/0,
            find_model: &__MODULE__.nil_model/2,
            get_model_auth: &__MODULE__.no_auth/1

  @doc false
  @spec empty_entries() :: []
  def empty_entries, do: []

  @doc false
  @spec nil_entry_id() :: nil
  def nil_entry_id, do: nil

  @doc false
  @spec nil_model(atom(), String.t()) :: nil
  def nil_model(_provider, _id), do: nil

  @doc false
  @spec no_auth(term()) :: {:error, String.t()}
  def no_auth(_model), do: {:error, "model registry not configured"}

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
