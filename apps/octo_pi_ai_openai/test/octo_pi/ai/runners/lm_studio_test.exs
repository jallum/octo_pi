defmodule OctoPi.AI.Runners.LMStudioTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Model
  alias OctoPi.AI.Runner
  alias OctoPi.AI.RunnerRegistry
  alias OctoPi.AI.Runners.LMStudio
  alias OctoPi.AI.TestSupport.FakeLMStudioPlug

  setup do
    prev = Application.get_env(:octo_pi_ai, :req_overrides, [])
    on_exit(fn -> Application.put_env(:octo_pi_ai, :req_overrides, prev) end)
    :ok
  end

  defp put_plug(plug), do: Application.put_env(:octo_pi_ai, :req_overrides, plug: plug)

  defp model_entry(id, opts \\ []) do
    %{
      "id" => id,
      "object" => "model",
      "type" => "llm",
      "max_context_length" => Keyword.get(opts, :ctx, 32_768),
      "loaded_context_length" => 4_096
    }
    |> Map.merge(Map.new(Keyword.get(opts, :extra, [])))
  end

  describe "behaviour callbacks" do
    test "implements OctoPi.AI.Runner" do
      Code.ensure_loaded!(LMStudio)
      callbacks = Runner.behaviour_info(:callbacks)

      Enum.each(callbacks, fn {name, arity} ->
        assert function_exported?(LMStudio, name, arity)
      end)
    end

    test "api/0" do
      assert LMStudio.api() == :openai_completions
    end

    test "default_base_url/0" do
      assert LMStudio.default_base_url() == "http://localhost:1234/v1"
    end

    test "auth/0 is :none" do
      assert LMStudio.auth() == :none
    end

    test "validate/1 accepts an empty config" do
      assert :ok = LMStudio.validate(%{})
    end

    test "validate/1 accepts base_url override" do
      assert :ok = LMStudio.validate(%{"base_url" => "http://10.0.0.5:1234/v1"})
    end

    test "validate/1 rejects non-string base_url" do
      assert {:error, _} = LMStudio.validate(%{"base_url" => 1234})
    end
  end

  describe "lookup/2" do
    test "returns Model for a known id" do
      put_plug(FakeLMStudioPlug.serve([model_entry("qwen2.5-coder-32b", ctx: 32_768)]))

      assert {:ok, %Model{} = m} = LMStudio.lookup("qwen2.5-coder-32b", %{})
      assert m.id == "qwen2.5-coder-32b"
      assert m.name == "qwen2.5-coder-32b"
      assert m.api == :openai_completions
      assert m.provider == :lmstudio
      assert m.base_url == "http://localhost:1234/v1"
      assert m.context_window == 32_768
    end

    test "returns Model honoring base_url override from config" do
      put_plug(FakeLMStudioPlug.serve([model_entry("model-a")]))

      config = %{"base_url" => "http://10.0.0.5:1234/v1"}
      assert {:ok, %Model{base_url: "http://10.0.0.5:1234/v1"}} = LMStudio.lookup("model-a", config)
    end

    test "returns :not_found for unknown id" do
      put_plug(FakeLMStudioPlug.serve([model_entry("only-this-one")]))
      assert :not_found = LMStudio.lookup("nope", %{})
    end

    test "returns {:error, _} when transport fails" do
      put_plug(fn _conn -> raise "boom" end)
      assert {:error, _} = LMStudio.lookup("anything", %{})
    end

    test "honors trained_for_tool_use / vision capability flags" do
      put_plug(
        FakeLMStudioPlug.serve([
          model_entry("vision-model",
            ctx: 8_192,
            extra: [{"trained_for_tool_use", true}, {"vision", true}]
          )
        ])
      )

      assert {:ok, m} = LMStudio.lookup("vision-model", %{})
      assert :image in m.input
      assert m.context_window == 8_192
    end
  end

  describe "discover/1" do
    test "returns the full list as Model.t()" do
      put_plug(
        FakeLMStudioPlug.serve([
          model_entry("a", ctx: 4096),
          model_entry("b", ctx: 8192)
        ])
      )

      assert {:ok, [a, b]} = LMStudio.discover(%{})
      assert %Model{id: "a", context_window: 4096} = a
      assert %Model{id: "b", context_window: 8192} = b
    end

    test "empty list when nothing is loaded" do
      put_plug(FakeLMStudioPlug.serve([]))
      assert {:ok, []} = LMStudio.discover(%{})
    end

    test "{:error, _} when transport fails" do
      put_plug(fn _conn -> raise "boom" end)
      assert {:error, _} = LMStudio.discover(%{})
    end
  end

  describe "registration" do
    test "is registered in OctoPi.AI.RunnerRegistry under :lmstudio" do
      assert RunnerRegistry.lookup(:lmstudio) == LMStudio
    end
  end
end
