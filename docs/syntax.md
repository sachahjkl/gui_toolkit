# syntax: the colours of source code

`import syntax "gt:syntax"` (the package is named `tk_syntax`). A lexer, not a parser: it puts runs of characters in
classes, and the program colours each class: the site's code blocks (`site.write_code_block`, spans of the style sheet),
a file manager's preview of a text (runs of rich text). Pure Odin, any target.

```odin
l, ok := syntax.language_of_file("main.odin")    // by its name or extension; or syntax.language("odin", project)
l, ok = syntax.guess(clipboard_text)             // a text with no name: by what it holds
spans: [dynamic]syntax.Span
syntax.spans(text, l, &spans)                    // {start, end, class}: in order, none overlapping, the plain left out
```

| Class | What |
|---|---|
| `Keyword` | the language's `keywords`, a `[section]`, a tag's name, an `@rule` |
| `Str` | a string or a character (`"`, `` ` ``, `'` when `char_quote`), cut at its line unless raw; a key's plain value |
| `Comment` | `line_comment` to the end of its line, `block_open` to `block_close` |
| `Func` | a name followed by `(`, a directive (`sigil`), C's `#` lines (`preprocessor`); a name given a value: a key, an attribute, a property |
| `Type` | the language's `types`, a number, a `$variable` (`variable`), a name that looks like a type (`Capital` then a small letter) |

`LANGUAGES`, in the order that breaks `guess`'s ties (the stricter languages first):

| Kind | Languages |
|---|---|
| Code | Odin, Zig, C (and C++'s files), C#, Java, Kotlin, Swift, Dart, JavaScript and TypeScript, PHP, PowerShell, SQL, Rust, Nix, the shell, Ruby, Lua, Python, Go |
| Data and configuration | JSON, TOML, INI (`.ini`, `.cfg`, `.conf`, `.desktop`, systemd units), YAML, Dockerfile, Makefile |
| Markup | HTML, XML (`.xml`, `.svg`, `.xaml`, `.csproj`, `.plist`...), CSS |
| Known, not coloured | Markdown, Diff (`highlight = false`: a label only) |

A `Language` says its `names` (a code block's info string), its `extensions`, its whole `file_names` (`Dockerfile`,
`Makefile`, `Gemfile`), its `label`, and its rules; a program gives its own to `language(name, project)` first.
`language_of_file` reads a file's whole name first (any case; `Dockerfile.dev` too; a path by its last part), then its
extension; it finds only languages with colours (`highlight`). `spans` gives no runs for a language without colours.

The rules of the data languages:

| Field | What |
|---|---|
| `key` | a name at a line's start (or after YAML's `- `) followed by this byte is a key, a `Func` (YAML's and a Makefile's `:`, TOML's and INI's `=`); a `:` key is followed by a space or the line's end |
| `sections` | a `[section]` at a line's start is a `Keyword` (TOML, INI) |
| `plain_values` | a key's unquoted value is a `Str` to its line's end or a ` #` comment (INI, YAML); a number, a keyword alone, a quoted string or a flow stays the tokenizer's |
| `variable` | `$name`, `${...}`, `$(NAME)` and make's `$@ $< $^` are a `Type` |

A block comment is tried before a line comment: Lua's `--[[` opens with its `--`.

## Markup

`Language.markup` cuts a text that is not words and statements with a lexer of its own (the fields of the word lexer are
not read):

- `.Tags` (HTML, XML): a tag's name is a `Keyword`; an attribute's name a `Func`, as a CSS property and a YAML key (a
  name given a value, so that the name and its value, a `Str`, stand apart); `<!-- -->` a `Comment`; `<!DOCTYPE>` and
  `<?xml ?>` a `Func` (directives, as C's `#` lines); `<![CDATA[ ]]>` a `Str`; `&amp;` a `Type`. The text between the
  tags stays plain: it is prose. A `<script>` holds JavaScript and a `<style>` CSS, coloured as such.
- `.Rules` (CSS): a statement that ends with `;` or `}` is a declaration, one that opens a block is a selector (the same
  test works on one line of an editor). In a selector, an element is a `Keyword`, `.class` and `#id` a `Type`, `:hover` a
  `Func`; a property is a `Func`; in a value, a number with its unit and a `#colour` are a `Type`, `url()` a `Func`; an
  `@rule` and `!important` are a `Keyword`; `/* */` a `Comment`.

## A text with no name

`guess(text, project)` finds the language of a text that comes with no file name (a copy, a paste). It reads the first
`GUESS_READ` bytes. The sure forms first, in this order:

1. a diff: a `diff --git` line, a `--- ` line over a `+++ ` line, or a `@@ -1,2 +1,3 @@` hunk header. Diff, even of code;
2. a `#!` line names its language (python, node, pwsh, sh); `<?php` is PHP;
3. a text that opens and closes as JSON is JSON;
4. a text that opens and ends with a tag is HTML when it says so (`<!DOCTYPE html>`) or holds one of HTML's common
   elements, XML otherwise;
5. a `[section]` and most lines `key = value`: TOML when every value is a typed one (quoted, a number, a boolean, an
   array, a table) and no section name holds a space, INI otherwise;
6. most lines `key: value` or `- item`, two keys at least, a nested key, a list item or `---`, no tab at a line's
   start: YAML (mail's headers have no structure, a Makefile has tabs);
7. Markdown: a fenced code block, or two kinds of its signs (a heading at a line's start, a list item at a line's
   start, a link `](http`, `**emphasis**`, a table's `| --- |`, a `> ` quote), or one of the last three with
   `` `inline code` ``. One sign is not enough: a note has a list, a script has `# ` comments.

Diff and Markdown come back with `ok = true` and `highlight = false`: a program shows its label, or renders the
Markdown, or colours the diff its own way; `spans` gives no runs for them.

Else each language with colours scores its `signs` found in the text (`GUESS_SIGN` each: pieces only its code is
likely to hold, such as `":= proc"` or `"#include"`) and its keywords found as words (one each, those of three letters
or more: prose says "if" and "for"). The best score wins from `GUESS_ENOUGH` on, and only for a text with the
punctuation of code: at least one bracket, operator or `;` for `GUESS_MARKS_PER` letters. ok = false otherwise: prose,
an address, a path. A project's languages (with their `signs`) are tried first.

`Language.fold_case` matches keywords and types in any case (SQL's `SELECT` and `select`; the lists in small letters).

## In a program's window

The `ui` package colours code with the theme: `code_runs(text, language, style, &runs)` makes runs for `rich_paragraph`
(`code_runs_of(text, spans, style, &runs)` with spans kept from an earlier `syntax.spans`: a text that does not change
is not lexed at each build), each class in its colour (`code_color`: the theme's `code_keyword`, `code_string`, `code_comment` in italics, `code_func`
and `code_type`), and `code_highlight(language)` gives `text_edit` its `highlight`, line by line (a block comment over
several lines is coloured on its first line only). The theme's colours are its hues: purple, green, the weak text, blue
and cyan (`Palette.blue`, `purple`, `cyan`, `rose`; the accent when a palette has none).

```odin
l, ok := syntax.guess(text)
if ok {
    runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
    ui.code_runs(text, l, {font = mono}, &runs)
    ui.rich_paragraph("###code", runs[:])
}
```
