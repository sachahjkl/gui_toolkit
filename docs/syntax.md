# syntax: the colours of source code

`import syntax "gt:syntax"` (the package is named `tk_syntax`). A lexer, not a parser: it puts runs of characters in
classes, and the program colours each class: the site's code blocks (`site.write_code_block`, spans of the style sheet),
a file manager's preview of a text (runs of rich text). Pure Odin, any target.

```odin
l, ok := syntax.language_of_file("main.odin")    // by its extension; or syntax.language("odin", project)
l, ok = syntax.guess(clipboard_text)             // a text with no name: by what it holds
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

`LANGUAGES`: Odin, C (and C++'s files), JavaScript and TypeScript, PowerShell, JSON, SQL, Rust, the shell, Python, Go, and HTML
and CSS without colours. A `Language` says its `names` (a code block's info string), its `extensions`, its `label`, and
its rules; a program gives its own to `language(name, project)` first. `language_of_file` finds only languages with
colours (`highlight`).

## A text with no name

`guess(text, project)` finds the language of a text that comes with no file name (a copy, a paste). It reads the first
`GUESS_READ` bytes: a `#!` line names its language (python, node, pwsh, sh); a text that opens and closes as JSON is
JSON; else each language with colours scores its `signs` found in the text (`GUESS_SIGN` each: pieces only its code is
likely to hold, such as `":= proc"` or `"#include"`) and its keywords found as words (one each, those of three letters
or more: prose says "if" and "for"). The best score wins from `GUESS_ENOUGH` on, and only for a text with the
punctuation of code: at least one bracket, operator or `;` for `GUESS_MARKS_PER` letters. ok = false otherwise: prose,
an address, a path. A project's languages (with their `signs`) are tried first.

`Language.fold_case` matches keywords and types in any case (SQL's `SELECT` and `select`; the lists in small letters).
