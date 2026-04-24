defmodule OctoPi.Coder.Extension.Event do
  @moduledoc false

  @fire_and_forget [
    :session_start, :session_shutdown, :session_compact, :session_tree,
    :agent_start, :agent_end, :turn_start, :turn_end,
    :message_start, :message_update, :message_end,
    :tool_execution_start, :tool_execution_update, :tool_execution_end,
    :model_select, :after_provider_response
  ]

  @cancel_on_result [
    :session_before_switch, :session_before_fork,
    :session_before_compact, :session_before_tree
  ]

  @reduce_chain [:context, :before_provider_request, :input]

  @mutate_in_place [:tool_call]

  @patch_merge [:tool_result]

  @first_result [:user_bash]

  @collect_all [:before_agent_start, :resources_discover]

  @all_types @fire_and_forget ++
               @cancel_on_result ++
               @reduce_chain ++
               @mutate_in_place ++
               @patch_merge ++
               @first_result ++
               @collect_all

  @type event_type ::
          :session_start | :session_shutdown | :session_compact | :session_tree |
          :agent_start | :agent_end | :turn_start | :turn_end |
          :message_start | :message_update | :message_end |
          :tool_execution_start | :tool_execution_update | :tool_execution_end |
          :model_select | :after_provider_response |
          :session_before_switch | :session_before_fork |
          :session_before_compact | :session_before_tree |
          :context | :before_provider_request | :input |
          :tool_call | :tool_result |
          :user_bash |
          :before_agent_start | :resources_discover

  @type pattern ::
          :fire_and_forget | :cancel_on_result | :reduce_chain |
          :mutate_in_place | :patch_merge | :first_result | :collect_all

  @type t :: %{:type => event_type(), optional(atom()) => term()}

  @spec event_types() :: [event_type()]
  def event_types, do: @all_types

  @spec valid?(atom()) :: boolean()
  def valid?(type), do: type in @all_types

  @spec pattern(event_type()) :: pattern()
  for t <- @fire_and_forget, do: def(pattern(unquote(t)), do: :fire_and_forget)
  for t <- @cancel_on_result, do: def(pattern(unquote(t)), do: :cancel_on_result)
  for t <- @reduce_chain, do: def(pattern(unquote(t)), do: :reduce_chain)
  for t <- @mutate_in_place, do: def(pattern(unquote(t)), do: :mutate_in_place)
  for t <- @patch_merge, do: def(pattern(unquote(t)), do: :patch_merge)
  for t <- @first_result, do: def(pattern(unquote(t)), do: :first_result)
  for t <- @collect_all, do: def(pattern(unquote(t)), do: :collect_all)
  def pattern(other), do: raise(ArgumentError, "unknown event type: #{inspect(other)}")

  @spec new(event_type(), map()) :: t()
  def new(type, payload \\ %{}) do
    unless valid?(type), do: raise(ArgumentError, "unknown event type: #{inspect(type)}")
    Map.put(payload, :type, type)
  end
end
