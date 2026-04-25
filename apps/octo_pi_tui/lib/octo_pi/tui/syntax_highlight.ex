defmodule OctoPi.TUI.SyntaxHighlight do
  @moduledoc false

  alias OctoPi.TUI.Theme

  @lang_aliases %{
    "js" => "javascript",
    "ts" => "typescript",
    "py" => "python",
    "rb" => "ruby",
    "sh" => "bash",
    "shell" => "bash",
    "zsh" => "bash",
    "ex" => "elixir",
    "exs" => "elixir"
  }

  @supported_languages MapSet.new([
                         "elixir",
                         "python",
                         "javascript",
                         "typescript",
                         "ruby",
                         "bash",
                         "rust",
                         "go",
                         "json"
                       ])

  @spec supported?(String.t()) :: boolean()
  def supported?(lang) do
    normalized = normalize_lang(lang)
    MapSet.member?(@supported_languages, normalized)
  end

  @spec highlight(String.t(), String.t(), Theme.t()) :: [String.t()]
  def highlight(code, lang, theme) do
    normalized = normalize_lang(lang)

    if MapSet.member?(@supported_languages, normalized) do
      code
      |> String.split("\n")
      |> Enum.map(&highlight_line(&1, normalized, theme))
    else
      String.split(code, "\n")
    end
  end

  defp normalize_lang(lang) do
    lower = String.downcase(lang)
    Map.get(@lang_aliases, lower, lower)
  end

  defp highlight_line("", _lang, _theme), do: ""

  defp highlight_line(line, lang, theme) do
    patterns = patterns_for(lang)
    apply_patterns(line, patterns, theme)
  end

  defp apply_patterns(line, patterns, theme) do
    Enum.reduce(patterns, line, fn {regex, color_key}, acc ->
      apply_one_pattern(acc, regex, color_key, theme)
    end)
  end

  @ansi_sequence ~r/\e\[[0-9;]*m/

  defp apply_one_pattern(text, regex, color_key, theme) do
    segments = Regex.split(@ansi_sequence, text, include_captures: true)
    Enum.map_join(segments, "", &colorize_segment(&1, regex, color_key, theme))
  end

  defp colorize_segment(segment, regex, color_key, theme) do
    if Regex.match?(@ansi_sequence, segment) do
      segment
    else
      Regex.replace(regex, segment, fn match -> Theme.fg(theme, color_key, match) end)
    end
  end

  defp patterns_for("elixir") do
    [
      {~r/#.*$/, :syntax_comment},
      {~r/"(?:[^"\\]|\\.)*"/, :syntax_string},
      {~r/'(?:[^'\\]|\\.)*'/, :syntax_string},
      {~r/:[a-zA-Z_]\w*/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b/, :syntax_number},
      {~r/\b(?:def|defp|defmodule|defstruct|defimpl|defprotocol|defmacro|defmacrop|defguard|defguardp|defdelegate|do|end|if|else|unless|case|cond|when|with|for|fn|raise|rescue|try|catch|after|receive|import|alias|require|use|in|and|or|not)\b/,
       :syntax_keyword},
      {~r/\b[A-Z]\w*/, :syntax_type},
      {~r/\|>|->|<-|=>|&&|\|\||!=|==|>=|<=|=~|\+\+|--/, :syntax_operator}
    ]
  end

  defp patterns_for("python") do
    [
      {~r/#.*$/, :syntax_comment},
      {~r/"""[\s\S]*?"""|'''[\s\S]*?'''/, :syntax_string},
      {~r/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b/, :syntax_number},
      {~r/\b(?:def|class|if|elif|else|for|while|return|import|from|as|try|except|finally|with|yield|raise|pass|break|continue|and|or|not|in|is|lambda|True|False|None|async|await)\b/,
       :syntax_keyword},
      {~r/\b[A-Z]\w*/, :syntax_type}
    ]
  end

  defp patterns_for(lang) when lang in ["javascript", "typescript"] do
    [
      {~r|//.*$|, :syntax_comment},
      {~r/`(?:[^`\\]|\\.)*`/, :syntax_string},
      {~r/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b/, :syntax_number},
      {~r/\b(?:const|let|var|function|class|if|else|for|while|return|import|export|from|as|try|catch|finally|throw|new|typeof|instanceof|async|await|yield|switch|case|break|continue|default|true|false|null|undefined|this|super|extends|implements|interface|type|enum)\b/,
       :syntax_keyword},
      {~r/\b[A-Z]\w*/, :syntax_type},
      {~r/=>|===|!==|&&|\|\||\?\?|\.\.\./, :syntax_operator}
    ]
  end

  defp patterns_for("ruby") do
    [
      {~r/#.*$/, :syntax_comment},
      {~r/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, :syntax_string},
      {~r/:[a-zA-Z_]\w*/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?\b/, :syntax_number},
      {~r/\b(?:def|class|module|if|elsif|else|unless|case|when|while|until|for|do|end|begin|rescue|ensure|raise|return|yield|require|include|extend|attr_reader|attr_writer|attr_accessor|true|false|nil|self|super)\b/,
       :syntax_keyword}
    ]
  end

  defp patterns_for("bash") do
    [
      {~r/#.*$/, :syntax_comment},
      {~r/"(?:[^"\\]|\\.)*"|'[^']*'/, :syntax_string},
      {~r/\$\w+|\$\{[^}]+\}/, :syntax_variable},
      {~r/\b\d+\b/, :syntax_number},
      {~r/\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|export|source|local|readonly|declare|typeset|unset|shift|eval|exec|trap|set)\b/,
       :syntax_keyword}
    ]
  end

  defp patterns_for("rust") do
    [
      {~r|//.*$|, :syntax_comment},
      {~r/"(?:[^"\\]|\\.)*"/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?(?:u8|u16|u32|u64|u128|usize|i8|i16|i32|i64|i128|isize|f32|f64)?\b/,
       :syntax_number},
      {~r/\b(?:fn|let|mut|const|static|struct|enum|impl|trait|type|pub|mod|use|crate|self|super|if|else|match|for|while|loop|break|continue|return|where|as|in|ref|move|async|await|unsafe|extern|dyn)\b/,
       :syntax_keyword},
      {~r/\b(?:bool|char|str|String|Vec|Option|Result|Box|Rc|Arc|i8|i16|i32|i64|i128|u8|u16|u32|u64|u128|f32|f64|usize|isize)\b/,
       :syntax_type}
    ]
  end

  defp patterns_for("go") do
    [
      {~r|//.*$|, :syntax_comment},
      {~r/"(?:[^"\\]|\\.)*"|`[^`]*`/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b/, :syntax_number},
      {~r/\b(?:func|var|const|type|struct|interface|map|chan|if|else|for|range|switch|case|default|select|break|continue|return|go|defer|package|import|fallthrough)\b/,
       :syntax_keyword},
      {~r/:=|<-|&&|\|\|/, :syntax_operator}
    ]
  end

  defp patterns_for("json") do
    [
      {~r/"(?:[^"\\]|\\.)*"\s*(?=:)/, :syntax_keyword},
      {~r/"(?:[^"\\]|\\.)*"/, :syntax_string},
      {~r/\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b/, :syntax_number},
      {~r/\b(?:true|false|null)\b/, :syntax_keyword}
    ]
  end

  defp patterns_for(_), do: []
end
