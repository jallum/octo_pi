%% Inline Markdown lexer for OctoPi.TUI.Components.Markdown.
%%
%% Produces a flat token stream the Elixir caller folds into AST
%% children. Longest-match across rules gives us the disambiguation
%% the hand-rolled per-char scanner couldn't express in one pass.
%%
%% Tokens:
%%   {text,   Line, IOlist}
%%   {escape, Line, IOlist}     -- the literal char following \, no parsing
%%   {code,   Line, IOlist}     -- inner text of a `code span` (verbatim)
%%   {strong, Line, IOlist}     -- inner text of **bold** / __bold__
%%   {em,     Line, IOlist}     -- inner text of *italic* / _italic_
%%   {del,    Line, IOlist}     -- inner text of ~~strike~~
%%   {link,   Line, {Text, Href}}
%%
%% Inner text of strong/em/del still has unparsed inline syntax —
%% the Elixir wrapper recurses through the lexer for nested cases.
%% Inner text of `code` and {escape, _, _} is returned verbatim.

Definitions.

ESCAPE      = \\.
BACKTICKED  = `[^`\n]+`
STRONGSTAR  = \*\*[^\n]+?\*\*
STRONGUSCR  = __[^\n]+?__
STRIKE      = ~~[^\n]+?~~
EMSTAR      = \*[^*\n]+\*
EMUSCR      = _[^_\n]+_
LINK        = \[[^\]\n]*\]\([^)\n]*\)
TEXT        = [^*_~`\[\\\n]+
NL          = \n
ANY         = .

Rules.

{ESCAPE}     : {token, {escape, TokenLine, lists:nthtail(1, TokenChars)}}.
{BACKTICKED} : {token, {code, TokenLine, strip_outer(TokenChars, 1)}}.
{STRONGSTAR} : {token, {strong, TokenLine, strip_outer(TokenChars, 2)}}.
{STRONGUSCR} : {token, {strong, TokenLine, strip_outer(TokenChars, 2)}}.
{STRIKE}     : {token, {del, TokenLine, strip_outer(TokenChars, 2)}}.
{EMSTAR}     : {token, {em, TokenLine, strip_outer(TokenChars, 1)}}.
{EMUSCR}     : {token, {em, TokenLine, strip_outer(TokenChars, 1)}}.
{LINK}       : {token, link_token(TokenChars, TokenLine)}.
{TEXT}       : {token, {text, TokenLine, TokenChars}}.
{NL}         : {token, {text, TokenLine, "\n"}}.
{ANY}        : {token, {text, TokenLine, TokenChars}}.

Erlang code.

strip_outer(Chars, N) ->
  L = length(Chars),
  lists:sublist(Chars, N + 1, L - 2 * N).

link_token(Chars, Line) ->
  {Text, Href} = split_link(Chars, []),
  {link, Line, {Text, Href}}.

%% Walk forward, stripping the leading `[`, capturing until `](`,
%% then taking the rest up to the trailing `)`.
split_link("[" ++ Rest, []) ->
  split_text(Rest, []);
split_link(_, _) ->
  {"", ""}.

split_text("](" ++ Rest, Acc) ->
  Text = lists:reverse(Acc),
  Href = strip_trailing_paren(Rest),
  {Text, Href};
split_text([H | T], Acc) ->
  split_text(T, [H | Acc]);
split_text([], Acc) ->
  {lists:reverse(Acc), ""}.

strip_trailing_paren(Str) ->
  case lists:reverse(Str) of
    [$) | Rest] -> lists:reverse(Rest);
    _ -> Str
  end.
