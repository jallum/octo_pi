defmodule OctoPi.Coder.Extensions.HelloTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.Hello

  describe "init/1" do
    test "registers a tool named 'hello'" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      assert Map.has_key?(ext.tools, "hello")
    end

    test "hello tool has the expected description" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      assert ext.tools["hello"].description == "A simple greeting tool"
    end

    test "hello tool has label 'Hello'" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      assert ext.tools["hello"].label == "Hello"
    end

    test "hello tool declares a required 'name' parameter" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      params = ext.tools["hello"].parameters
      assert params.type == :object
      assert Map.has_key?(params.properties, :name)
      assert "name" in params.required
    end

    test "registers no event handlers" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      assert ext.handlers == %{}
    end

    test "registers no commands" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      assert ext.commands == %{}
    end
  end

  describe "greet/1" do
    test "returns greeting text for given name" do
      result = Hello.greet(%{"name" => "World"})

      assert result.content == [%{type: "text", text: "Hello, World!"}]
    end

    test "details map includes the greeted name" do
      result = Hello.greet(%{"name" => "Alice"})

      assert result.details == %{greeted: "Alice"}
    end

    test "execute field in registered tool calls greet/1" do
      {:ok, ext} = Loader.load_from_factory("hello", &Hello.init/1)

      result = ext.tools["hello"].execute.(%{"name" => "Bob"})

      assert result.content == [%{type: "text", text: "Hello, Bob!"}]
    end
  end
end
