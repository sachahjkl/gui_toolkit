# diff: a unified diff, read and shown

`import diff "gt:diff"` (the package is named `tk_diff`). A unified diff read into its lines, two texts compared and written as
one, and a widget that shows the lines: numbers in two gutters, a sign, an added line on a tint of green and a removed one of red,
what changed in a changed line on a stronger tint, the code in its colours. A source control client, an editor's "what changed",
an agent's edits use the same rows.

## Reading a patch

A patch is git's or `diff -u`'s (file headers, hunks, several files), or the bare lines `between` writes (a sign then the text).

```odin
p := diff.parse(patch)            // in context.allocator; the lines' texts are slices of `patch`: keep it
for l in p.lines { ... }          // l.kind (.Same, .Added, .Removed, .Gap), l.text, l.old_no, l.new_no, l.lo, l.hi
p.numbered                        // it came with hunks: its lines have numbers
p.added, p.removed                // its counts
diff.parsed_destroy(&p)
```

| Procedure | What |
|---|---|
| `parse(patch, allocator)` | the lines, marked (`mark`), with `numbered`, `added`, `removed` |
| `parse_lines(patch, allocator)` | the lines alone, unmarked |
| `mark(lines)` | in a block of lines removed then added, the k-th of each are the same line changed: `lo`, `hi` say the bytes between what they share at each end (never inside a character); a pair that shares nothing is not marked |
| `between(old, new, allocator)` | `old` to `new` as the lines of a unified diff, without headers or hunks (core:diff): `" a\n-b\n+x\n c\n"` |
| `sign(kind)` | `' '`, `'+'`, `'-'`, `'@'` |
| `split_rows(lines, allocator)` | the rows of a split view: `Row{left, right}`, by index in the lines (-1: nothing on that side), a changed line facing itself |
| `visible_rows(offset, target, view_h, row_h, count, margin)` | the rows to build for a view of rows of one height: where it is, where it goes, and `margin` rows beyond (`VIEW_MARGIN_ROWS`) |

A line of a hunk begins with a sign, and only the counts of the hunk's header say where it ends: in a hunk, `--- x` is the line
`-- x` removed; out of one, a file's header. A hunk's header with no count (`@@ -1 +1 @@`) is one line. Two hunks have a `.Gap`
line between them. `\ No newline at end of file` is left out.

## Read once

Read a patch when it is new, never at each build. `parse` once and keep the result beside the patch, or keep a `Doc`: it owns its
text and reads it again only when it changes, so a build may hand it its patch every frame.

```odin
doc: diff.Doc
if diff.doc_set(&doc, patch) { ... }   // true: it was read (doc.version counts the readings)
doc.lines, doc.rows, doc.added, doc.removed
diff.doc_destroy(&doc)
```

## Showing it

```odin
o := diff.View_Options{font = mono, size = 13, number_size = 11, row_height = 17, language = lang, selectable = true}

diff.lines_view("###excerpt", p.lines[:min(len(p.lines), 16)], p.numbered, o)   // every row built: an excerpt
diff.view("###full", &doc, .Split, o)                                        // fills its parent, scrolls; only the rows in view built
```

`lines_view` builds a column of rows, one per line given: a program shows the first lines of a patch and its own way to the whole.
`view` builds a box that fills its parent and scrolls (it returns it): `.Stacked` shows the lines as the patch has them, `.Split`
the old on the left and the new on the right. Every row has one height, so what is built is a sum, whatever the length.

`View_Options` (pixels; 0: the default):

| Field | What |
|---|---|
| `font`, `sign_font`, `number_font` | the faces of the text, the sign, the numbers (`ui.mono_font()`) |
| `size`, `number_size` | the text's size (`ui.font_size()`), the numbers' (`size`) |
| `row_height`, `gap_height` | a row (1.5 × size), the row between two hunks in `lines_view` (`row_height`) |
| `gutter_width`, `sign_width`, `indent` | one column of numbers, the sign, the space before the sign |
| `tab` | what a tab shows (four spaces) |
| `max_bytes` | a line cut there, at a character, with "…" (0: all of it) |
| `language` | the code's colours (`tk_syntax`: `syntax.language_of_file(name)`) |
| `selectable` | the text can be selected and copied |

The colours are the theme's, under the tag `diff`: `diff_added background`, `diff_removed background`, `diff_added mark`,
`diff_removed mark` (what changed in a line), `diff_added text`, `diff_removed text`, `diff text`, `diff_added sign`,
`diff_removed sign`, `diff sign`, `diff mark_text` (a marked part's text without a code colour), `diff line_number`, `diff gap`,
`diff divider`. The palette makes them from its good and bad colours; a program sets its own with `ui.theme_add` before the
palette (the first of equal patterns wins: add those of a kind, `diff_added …`, before the plain `diff …`).

The words around it (a title, "Copy", "Full view", a count of the lines left out) and what a click on it does are the program's.
