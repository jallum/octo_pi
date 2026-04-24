defmodule OctoPi.Coder.Extension.ContextTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context

  describe "new/1" do
    test "creates context with defaults" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.cwd == "/tmp"
      assert ctx.model == nil
      assert ctx.session_id == nil
      assert ctx.idle? == false
      assert ctx.signal == nil
    end

    test "accepts all fields" do
      ctx =
        Context.new(%{
          cwd: "/home",
          model: %{id: "test-model"},
          session_id: "sess-123",
          idle?: true,
          signal: make_ref()
        })

      assert ctx.cwd == "/home"
      assert ctx.model.id == "test-model"
      assert ctx.session_id == "sess-123"
      assert ctx.idle?
      assert is_reference(ctx.signal)
    end
  end
end
