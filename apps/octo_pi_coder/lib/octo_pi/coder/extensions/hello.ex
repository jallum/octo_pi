defmodule OctoPi.Coder.Extensions.Hello do
  @moduledoc """
  Minimal custom tool example. Registers a "hello" tool that greets by name.
  Ported from examples/extensions/hello.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.register_tool(api, %{
      name: "hello",
      label: "Hello",
      description: "A simple greeting tool",
      parameters: %{
        type: :object,
        properties: %{name: %{type: :string, description: "Name to greet"}},
        required: ["name"]
      },
      execute: &greet/1
    })
  end

  @doc "Return a greeting map for the given parameter map."
  @spec greet(map()) :: %{content: [map()], details: map()}
  def greet(%{"name" => name}) do
    %{content: [%{type: "text", text: "Hello, #{name}!"}], details: %{greeted: name}}
  end
end
