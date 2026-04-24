defmodule OctoPi.Coder.Extension.UIContextTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.UIContext

  describe "new/0" do
    test "all fields are stubs that raise" do
      ctx = UIContext.new()

      assert_raise RuntimeError, ~r/not bound/, fn -> ctx.notify.("hello") end
      assert_raise RuntimeError, ~r/not bound/, fn -> ctx.get_theme.() end
      assert_raise RuntimeError, ~r/not bound/, fn -> ctx.custom.(:widget, []) end
      assert_raise RuntimeError, ~r/not bound/, fn -> ctx.select.([], []) end
      assert_raise RuntimeError, ~r/not bound/, fn -> ctx.confirm.("sure?", []) end
    end
  end

  describe "bind/2" do
    test "replaces stubs with real implementations" do
      ctx = UIContext.new()

      bound =
        UIContext.bind(ctx, %{
          notify: fn msg -> {:notified, msg} end,
          get_theme: fn -> "dark" end,
          select: fn opts, _kw -> {:ok, hd(opts).value} end,
          custom: fn widget, _opts -> {:rendered, widget} end
        })

      assert {:notified, "hi"} == bound.notify.("hi")
      assert "dark" == bound.get_theme.()
      assert {:ok, :a} == bound.select.([%{label: "A", value: :a}], [])
      assert {:rendered, :my_widget} == bound.custom.(:my_widget, [])
    end

    test "partial bind leaves unbound stubs" do
      ctx = UIContext.new()
      bound = UIContext.bind(ctx, %{notify: fn _ -> :ok end})

      assert :ok == bound.notify.("test")
      assert_raise RuntimeError, ~r/not bound/, fn -> bound.get_theme.() end
    end
  end

  describe "dialog methods" do
    test "confirm returns boolean when bound" do
      ctx = UIContext.new() |> UIContext.bind(%{confirm: fn _msg, _opts -> true end})
      assert true == ctx.confirm.("Are you sure?", [])
    end

    test "input returns {:ok, text} when bound" do
      ctx =
        UIContext.new() |> UIContext.bind(%{input: fn _prompt, _opts -> {:ok, "user input"} end})

      assert {:ok, "user input"} == ctx.input.("Enter value:", [])
    end

    test "editor returns {:ok, text} when bound" do
      ctx =
        UIContext.new() |> UIContext.bind(%{editor: fn _initial, _opts -> {:ok, "edited"} end})

      assert {:ok, "edited"} == ctx.editor.("initial", [])
    end
  end

  describe "theme methods" do
    test "get/set theme" do
      theme = "monokai"

      ctx =
        UIContext.new()
        |> UIContext.bind(%{
          get_theme: fn -> theme end,
          set_theme: fn _t -> :ok end,
          get_all_themes: fn -> ["dark", "light", "monokai"] end
        })

      assert "monokai" == ctx.get_theme.()
      assert :ok == ctx.set_theme.("dark")
      assert ["dark", "light", "monokai"] == ctx.get_all_themes.()
    end
  end

  describe "editor control" do
    test "paste/get/set editor text" do
      ctx =
        UIContext.new()
        |> UIContext.bind(%{
          paste_to_editor: fn _text -> :ok end,
          set_editor_text: fn _text -> :ok end,
          get_editor_text: fn -> "current text" end
        })

      assert :ok == ctx.paste_to_editor.("pasted")
      assert :ok == ctx.set_editor_text.("new text")
      assert "current text" == ctx.get_editor_text.()
    end
  end
end
