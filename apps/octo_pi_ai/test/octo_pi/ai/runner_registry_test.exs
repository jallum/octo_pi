defmodule OctoPi.AI.RunnerRegistryTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.RunnerRegistry

  setup do
    snapshot = RunnerRegistry.list()

    on_exit(fn ->
      for name <- Map.keys(RunnerRegistry.list()), name not in Map.keys(snapshot) do
        RunnerRegistry.unregister(name)
      end
    end)

    :ok
  end

  describe "register/2 + lookup/1" do
    test "lookup returns nil when nothing is registered for a name" do
      assert RunnerRegistry.lookup(:nonexistent_runner) == nil
    end

    test "register then lookup round-trips" do
      assert :ok = RunnerRegistry.register(:test_runner, SomeRunnerModule)
      assert RunnerRegistry.lookup(:test_runner) == SomeRunnerModule
    end

    test "register overwrites prior registration" do
      RunnerRegistry.register(:test_runner, FirstRunner)
      RunnerRegistry.register(:test_runner, SecondRunner)
      assert RunnerRegistry.lookup(:test_runner) == SecondRunner
    end

    test "list returns all current registrations" do
      RunnerRegistry.register(:r_a, A)
      RunnerRegistry.register(:r_b, B)
      all = RunnerRegistry.list()
      assert all[:r_a] == A
      assert all[:r_b] == B
    end
  end
end
