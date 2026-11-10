# syntax: the colours of source code

`import syntax "gt:syntax"` (the package is named `tk_syntax`). A lexer, not a parser: it puts runs of characters in
classes, and the program colours each class: the site's code blocks (`site.write_code_block`, spans of the style sheet),
a file manager's preview of a text (runs of rich text). Pure Odin, any target.

```odin
l, ok := syntax.language_of_file("main.odin")    // by its extension; or syntax.language("odin", project)
spans: [dynamic]syntax.Span
syntax.spans(text, l, &spans)                    // {start, end, class}: in order, none overlapping, the plain left out
```

| Class | What |
|---|---|
| `Keyword` | the language's `keywords` |
| `Str` | a string or a character (`"`, `` ` ``, `'` when `char_quote`), cut at its line unless raw |
| `Comment` | `line_comment` to the end of its line, `block_open` to `block_close` |
| `Func` | a name followed by `(`, a directive (`sigil`), C's `#` lines (`preprocessor`) |
| `Type` | the language's `types`, a number, a `$variable` (`variable`), a name that looks like a type (`Capital` then a small letter) |

`LANGUAGES`: Odin, C (and C++'s files), JavaScript and TypeScript, PowerShell, JSON, Rust, the shell, Python, Go, and HTML
and CSS without colours. A `Language` says its `names` (a code block's info string), its `extensions`, its `label`, and
its rules; a program gives its own to `language(name, project)` first. `language_of_file` finds only languages with
colours (`highlight`).
