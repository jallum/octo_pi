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

    test "get_entries defaults to a function returning an empty list" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.get_entries.() == []
    end

    test "accepts a custom get_entries function" do
      entries = [:a, :b]
      ctx = Context.new(%{cwd: "/tmp", get_entries: fn -> entries end})
      assert ctx.get_entries.() == entries
    end

    test "get_leaf_entry_id defaults to a function returning nil" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.get_leaf_entry_id.() == nil
    end

    test "accepts a custom get_leaf_entry_id function" do
      ctx = Context.new(%{cwd: "/tmp", get_leaf_entry_id: fn -> "entry-abc" end})
      assert ctx.get_leaf_entry_id.() == "entry-abc"
    end

    test "get_branch defaults to a function returning an empty list" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.get_branch.() == []
    end

    test "accepts a custom get_branch function" do
      entries = [:msg1, :msg2]
      ctx = Context.new(%{cwd: "/tmp", get_branch: fn -> entries end})
      assert ctx.get_branch.() == entries
    end

    test "find_model defaults to a function returning nil" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.find_model.(:google, "gemini-2.5-flash") == nil
    end

    test "accepts a custom find_model function" do
      model = %{id: "test-model", provider: :test}
      ctx = Context.new(%{cwd: "/tmp", find_model: fn _provider, _id -> model end})
      assert ctx.find_model.(:test, "test-model") == model
    end

    test "get_model_auth defaults to returning an error tuple" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert match?({:error, _}, ctx.get_model_auth.(%{}))
    end

    test "accepts a custom get_model_auth function" do
      auth = %{api_key: "sk-test"}
      ctx = Context.new(%{cwd: "/tmp", get_model_auth: fn _model -> {:ok, auth} end})
      assert ctx.get_model_auth.(%{}) == {:ok, auth}
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
