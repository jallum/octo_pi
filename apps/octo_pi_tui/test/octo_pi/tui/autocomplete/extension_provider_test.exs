defmodule OctoPi.TUI.Autocomplete.ExtensionProviderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.{CombinedProvider, ExtensionProvider, Suggestion}

  describe "ExtensionProvider" do
    test "wraps a function into Autocomplete behaviour" do
      fun = fn input ->
        if String.starts_with?(input, "/"),
          do: ["custom_cmd"],
          else: []
      end

      provider = ExtensionProvider.new(fun)
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/c")
      assert [%Suggestion{label: "custom_cmd", value: "custom_cmd"}] = suggestions
    end

    test "returns empty for no matches" do
      fun = fn _input -> [] end
      provider = ExtensionProvider.new(fun)
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "anything")
      assert suggestions == []
    end
  end

  describe "stacking with CombinedProvider" do
    test "extension suggestions appear alongside base suggestions" do
      base_fn = fn _input -> ["base_item"] end
      ext_fn = fn _input -> ["ext_item"] end

      base = ExtensionProvider.new(base_fn)
      ext = ExtensionProvider.new(ext_fn)
      combined = CombinedProvider.new([base, ext])

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "test")
      labels = Enum.map(suggestions, & &1.label)
      assert "base_item" in labels
      assert "ext_item" in labels
    end

    test "deduplicates by value" do
      fn1 = fn _input -> ["same"] end
      fn2 = fn _input -> ["same"] end

      combined =
        CombinedProvider.new([
          ExtensionProvider.new(fn1),
          ExtensionProvider.new(fn2)
        ])

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "test")
      assert length(suggestions) == 1
    end
  end

  describe "add_provider/2" do
    test "adds to existing combined provider" do
      base = ExtensionProvider.new(fn _ -> ["a"] end)
      combined = CombinedProvider.new([base])

      ext = ExtensionProvider.new(fn _ -> ["b"] end)
      combined = ExtensionProvider.add_provider(combined, ext)

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "x")
      labels = Enum.map(suggestions, & &1.label)
      assert "a" in labels
      assert "b" in labels
    end

    test "wraps nil provider into combined with new provider" do
      ext = ExtensionProvider.new(fn _ -> ["only"] end)
      combined = ExtensionProvider.add_provider(nil, ext)

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "x")
      assert [%Suggestion{label: "only"}] = suggestions
    end

    test "wraps non-combined provider into combined" do
      base = ExtensionProvider.new(fn _ -> ["base"] end)
      ext = ExtensionProvider.new(fn _ -> ["ext"] end)
      combined = ExtensionProvider.add_provider(base, ext)

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "x")
      labels = Enum.map(suggestions, & &1.label)
      assert "base" in labels
      assert "ext" in labels
    end
  end
end
