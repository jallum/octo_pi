defmodule OctoPi.Coder.Extensions.ProviderPayloadTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.ProviderPayload

  defp ext_with_log do
    {:ok, log} = Agent.start_link(fn -> [] end)
    log_fn = fn entry -> Agent.update(log, fn acc -> [entry | acc] end) end
    {:ok, ext} = Loader.load_from_factory("provider-payload", fn api -> ProviderPayload.init(api, log_fn) end)
    {ext, log}
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  describe "init/2" do
    test "registers a before_provider_request handler" do
      {ext, _} = ext_with_log()
      assert Map.has_key?(ext.handlers, :before_provider_request)
    end

    test "registers an after_provider_response handler" do
      {ext, _} = ext_with_log()
      assert Map.has_key?(ext.handlers, :after_provider_response)
    end

    test "registers no tools or commands" do
      {ext, _} = ext_with_log()
      assert ext.tools == %{}
      assert ext.commands == %{}
    end
  end

  describe "before_provider_request handler" do
    test "logs the request payload" do
      {ext, log} = ext_with_log()
      [handler] = ext.handlers[:before_provider_request]
      payload = %{messages: [%{role: "user"}], model: "claude-3"}
      event = %{type: :before_provider_request, messages: payload}
      handler.(event, ctx())
      assert length(Agent.get(log, & &1)) == 1
    end

    test "log entry contains request type" do
      {ext, log} = ext_with_log()
      [handler] = ext.handlers[:before_provider_request]
      payload = %{messages: [%{role: "user"}]}
      event = %{type: :before_provider_request, messages: payload}
      handler.(event, ctx())
      [entry] = Agent.get(log, & &1)
      assert entry =~ "request" or is_map(entry)
    end

    test "returns nil to keep payload unchanged" do
      {ext, _} = ext_with_log()
      [handler] = ext.handlers[:before_provider_request]
      payload = %{messages: [], model: "claude-3"}
      event = %{type: :before_provider_request, messages: payload}
      result = handler.(event, ctx())
      assert is_nil(result)
    end
  end

  describe "after_provider_response handler" do
    test "logs the response event" do
      {ext, log} = ext_with_log()
      handler = hd(ext.handlers[:after_provider_response])
      event = Event.new(:after_provider_response, %{status: 200, headers: %{}})
      handler.(event, ctx())
      assert length(Agent.get(log, & &1)) == 1
    end

    test "log entry contains response type" do
      {ext, log} = ext_with_log()
      handler = hd(ext.handlers[:after_provider_response])
      event = Event.new(:after_provider_response, %{status: 200, headers: %{"x-req-id" => "abc"}})
      handler.(event, ctx())
      [entry] = Agent.get(log, & &1)
      assert entry =~ "response" or is_map(entry)
    end
  end
end
