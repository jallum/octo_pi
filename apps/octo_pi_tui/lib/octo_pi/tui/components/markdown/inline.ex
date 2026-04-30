defmodule OctoPi.TUI.Components.Markdown.Inline do
  @moduledoc """
  Inline parser. Wraps the leex lexer at `src/octo_pi_md_inline_lex.xrl`
  and folds its token stream into the native inline AST:

      inline ::= String.t()
               | {:strong, [inline]}
               | {:em, [inline]}
               | {:code, String.t()}
               | {:del, [inline]}
               | {:link, href :: String.t(), [inline]}

  Inner content of `:strong` / `:em` / `:del` is recursively parsed so
  nested emphasis works. `:code` and escapes are returned verbatim.
  """

  @type inline ::
          String.t()
          | {:strong, [inline]}
          | {:em, [inline]}
          | {:code, String.t()}
          | {:del, [inline]}
          | {:link, String.t(), [inline]}

  @spec parse(String.t()) :: [inline]
  def parse(""), do: []

  def parse(text) when is_binary(text) do
    case :octo_pi_md_inline_lex.string(String.to_charlist(text)) do
      {:ok, tokens, _} -> tokens |> Enum.map(&token_to_child/1) |> coalesce_text()
      {:error, _, _} -> [text]
    end
  end

  defp token_to_child({:text, _, chars}), do: List.to_string(chars)
  defp token_to_child({:escape, _, chars}), do: List.to_string(chars)
  defp token_to_child({:code, _, chars}), do: {:code, List.to_string(chars)}
  defp token_to_child({:strong, _, chars}), do: {:strong, parse(List.to_string(chars))}
  defp token_to_child({:em, _, chars}), do: {:em, parse(List.to_string(chars))}
  defp token_to_child({:del, _, chars}), do: {:del, parse(List.to_string(chars))}

  defp token_to_child({:link, _, {text_chars, href_chars}}) do
    {:link, List.to_string(href_chars), parse(List.to_string(text_chars))}
  end

  defp coalesce_text(children), do: coalesce_text(children, [])

  defp coalesce_text([], acc), do: Enum.reverse(acc)

  defp coalesce_text([a, b | rest], acc) when is_binary(a) and is_binary(b) do
    coalesce_text([a <> b | rest], acc)
  end

  defp coalesce_text([head | rest], acc), do: coalesce_text(rest, [head | acc])
end
