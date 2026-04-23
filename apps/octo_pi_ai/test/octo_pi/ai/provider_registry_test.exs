defmodule OctoPi.AI.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.ProviderRegistry

  # Assumes the registry is started by OctoPi.AI.Application. Each test
  # cleans up any keys it touched in on_exit.

  setup do
    # Snapshot existing registrations so we can restore them.
    snapshot = ProviderRegistry.list()

    on_exit(fn ->
      for api <- Map.keys(ProviderRegistry.list()), api not in Map.keys(snapshot) do
        ProviderRegistry.unregister(api)
      end
    end)

    :ok
  end

  describe "register/2 + lookup/1" do
    test "lookup returns nil when the api is not registered" do
      assert ProviderRegistry.lookup(:nonexistent_api) == nil
    end

    test "register then lookup round-trips" do
      assert :ok = ProviderRegistry.register(:test_api, SomeProviderModule)
      assert ProviderRegistry.lookup(:test_api) == SomeProviderModule
    end

    test "register is idempotent — a second call overwrites the first" do
      ProviderRegistry.register(:test_api, First)
      ProviderRegistry.register(:test_api, Second)
      assert ProviderRegistry.lookup(:test_api) == Second
    end

    test "list returns all current registrations" do
      ProviderRegistry.register(:api_a, A)
      ProviderRegistry.register(:api_b, B)
      all = ProviderRegistry.list()
      assert all[:api_a] == A
      assert all[:api_b] == B
    end
  end

  describe "concurrent register/2" do
    test "two concurrent registers of different apis don't lose either" do
      tasks =
        for {api, mod} <- [{:concurrent_a, ModA}, {:concurrent_b, ModB}] do
          Task.async(fn -> ProviderRegistry.register(api, mod) end)
        end

      Enum.each(tasks, &Task.await/1)

      assert ProviderRegistry.lookup(:concurrent_a) == ModA
      assert ProviderRegistry.lookup(:concurrent_b) == ModB
    end
  end
end
