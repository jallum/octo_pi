defmodule OctoPi.Coder.Extension.Context do
  @moduledoc false

  alias OctoPi.Agent.Message
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Session

  @type t :: %__MODULE__{
          cwd: String.t(),
          model: term(),
          session_id: String.t() | nil,
          idle?: boolean(),
          signal: reference() | nil,
          has_ui?: boolean(),
          ui: OctoPi.Coder.Extension.UIContext.t() | nil,
          get_entries: (-> [Session.Entry.t()]),
          get_messages: (-> [Message.t()]),
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
            get_entries: &__MODULE__.empty_list/0,
            get_messages: &__MODULE__.empty_list/0,
            get_branch: &__MODULE__.empty_list/0,
            get_leaf_entry_id: &__MODULE__.nil_entry_id/0,
            find_model: &OctoPi.Coder.Models.find/2,
            get_model_auth: &__MODULE__.no_auth/1

  @doc false
  @spec empty_list() :: []
  def empty_list, do: []

  @doc false
  @spec nil_entry_id() :: nil
  def nil_entry_id, do: nil

  @doc false
  @spec no_auth(term()) :: {:error, String.t()}
  def no_auth(_model), do: {:error, "model registry not configured"}

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
