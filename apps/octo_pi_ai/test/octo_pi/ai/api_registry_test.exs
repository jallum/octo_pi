defmodule OctoPi.AI.ApiRegistryTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.ApiRegistry

  # Assumes the registry is started by OctoPi.AI.Application. Each test
  # cleans up any keys it touched in on_exit.

  setup do
    # Snapshot existing registrations so we can restore them.
    snapshot = ApiRegistry.list()

    on_exit(fn ->
      for api <- Map.keys(ApiRegistry.list()), api not in Map.keys(snapshot) do
        ApiRegistry.unregister(api)
      end
    end)

    :ok
  end

  describe "register/2 + lookup/1" do
    test "lookup returns nil when the api is not registered" do
      assert ApiRegistry.lookup(:nonexistent_api) == nil
    end

    test "register then lookup round-trips" do
      assert :ok = ApiRegistry.register(:test_api, SomeProviderModule)
      assert ApiRegistry.lookup(:test_api) == SomeProviderModule
    end

    test "register is idempotent — a second call overwrites the first" do
      ApiRegistry.register(:test_api, First)
      ApiRegistry.register(:test_api, Second)
      assert ApiRegistry.lookup(:test_api) == Second
    end

    test "list returns all current registrations" do
      ApiRegistry.register(:api_a, A)
      ApiRegistry.register(:api_b, B)
      all = ApiRegistry.list()
      assert all[:api_a] == A
      assert all[:api_b] == B
    end
  end

  describe "concurrent register/2" do
    test "two concurrent registers of different apis don't lose either" do
      tasks =
        for {api, mod} <- [{:concurrent_a, ModA}, {:concurrent_b, ModB}] do
          Task.async(fn -> ApiRegistry.register(api, mod) end)
        end

      Enum.each(tasks, &Task.await/1)

      assert ApiRegistry.lookup(:concurrent_a) == ModA
      assert ApiRegistry.lookup(:concurrent_b) == ModB
    end
  end
end
