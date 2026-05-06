defmodule OctoPi.AI.ModelTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.{Model, Usage}

  defp model_with_pricing do
    %Model{
      id: "test-model",
      name: "Test",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://api.example.com/v1",
      context_window: 128_000,
      max_tokens: 4_096,
      cost: %Model.Cost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 3.75}
    }
  end

  describe "calculate_cost/2" do
    test "computes per-field and total cost from per-million-token rates" do
      usage = %Usage{input: 1_000, output: 500, cache_read: 200, cache_write: 100}
      result = Model.calculate_cost(model_with_pricing(), usage)

      assert_in_delta result.cost.input, 1_000 / 1_000_000 * 2.5, 1.0e-9
      assert_in_delta result.cost.output, 500 / 1_000_000 * 10.0, 1.0e-9
      assert_in_delta result.cost.cache_read, 200 / 1_000_000 * 1.25, 1.0e-9
      assert_in_delta result.cost.cache_write, 100 / 1_000_000 * 3.75, 1.0e-9

      expected_total =
        1_000 / 1_000_000 * 2.5 +
          500 / 1_000_000 * 10.0 +
          200 / 1_000_000 * 1.25 +
          100 / 1_000_000 * 3.75

      assert_in_delta result.cost.total, expected_total, 1.0e-9
    end

    test "returns zero cost when model has default (zero) pricing" do
      zero_model = %{model_with_pricing() | cost: %Model.Cost{}}
      usage = %Usage{input: 1_000, output: 500}
      result = Model.calculate_cost(zero_model, usage)

      assert result.cost.total == 0.0
    end

    test "preserves all other usage fields" do
      usage = %Usage{input: 100, output: 50, cache_read: 10, cache_write: 5, total_tokens: 165}
      result = Model.calculate_cost(model_with_pricing(), usage)

      assert result.input == 100
      assert result.output == 50
      assert result.cache_read == 10
      assert result.cache_write == 5
      assert result.total_tokens == 165
    end
  end
end
