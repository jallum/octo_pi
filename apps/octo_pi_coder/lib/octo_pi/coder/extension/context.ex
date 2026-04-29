defmodule OctoPi.Coder.Extension.Context do
  @moduledoc false

  alias OctoPi.Agent.Message
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Models
  alias OctoPi.Coder.Session
  alias OctoPi.Coder.SessionManager

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
          get_branch: (-> [Session.Entry.t()]),
          get_leaf_entry_id: (-> String.t() | nil),
          find_model: (atom(), String.t() -> Model.t() | nil),
          get_model_auth: (Model.t() -> {:ok, map()} | {:error, String.t()}),
          summary_producer: (term(), term(), term() -> Enumerable.t()) | nil
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
            find_model: &Models.find/2,
            get_model_auth: &__MODULE__.no_auth/1,
            summary_producer: nil

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

  @doc """
  Wire `get_entries`, `get_branch`, and `get_leaf_entry_id` to a
  `SessionManager`. Pass either a `%SessionManager{}` (snapshot) or a
  zero-arity getter that returns the current `%SessionManager{}` (use
  this when the manager lives behind a process and may change).

  Mirrors pi-mono's pattern of exposing `sessionManager` to extensions
  for branch / leaf / entries access (`extensions/types.ts:301`).
  """
  @spec bind_session_manager(t(), SessionManager.t() | (-> SessionManager.t())) :: t()
  def bind_session_manager(%__MODULE__{} = ctx, %SessionManager{} = sm) do
    bind_session_manager(ctx, fn -> sm end)
  end

  def bind_session_manager(%__MODULE__{} = ctx, get_sm) when is_function(get_sm, 0) do
    %{
      ctx
      | get_entries: fn -> SessionManager.get_entries(get_sm.()) end,
        get_branch: fn -> SessionManager.get_branch(get_sm.()) end,
        get_leaf_entry_id: fn -> SessionManager.get_leaf_entry_id(get_sm.()) end
    }
  end

  @doc """
  Wire the `SessionManager` getters to a live `OctoPi.Coder.Session`
  pid. Convenience around `bind_session_manager/2` for the common
  case where the manager lives behind the session GenServer.
  """
  @spec bind_session(t(), GenServer.server()) :: t()
  def bind_session(%__MODULE__{} = ctx, session) do
    bind_session_manager(ctx, fn -> GenServer.call(session, :get_session_manager) end)
  end
end
