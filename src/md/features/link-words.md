# Link words

A program's texts name its own things: opencode's sessions by their id (`ses_…`). opencode 2.3.0 opens a session
from its id in a message. The toolkit makes the web addresses of a text links (`rich_links`, Markdown's bare
addresses); a program now gives it the prefixes of its own words, and such a word is a link too.

## The decision

- `link_words_set(prefixes)`, once at the start: a word that starts with one of the prefixes, followed by at least one
  letter, digit or `_`, is a link. Its target is the word itself. The program's link handler (it already opens what a
  link says) knows the prefix and does what the word means.
- One test of a link, `link_len(text, i)`: a web address or a link word. `rich_links` and Markdown's inline runs both
  call it, so a link word is a link in plain text, in Markdown, and alone in inline code (`` `ses_abc` ``) as an
  address is.
- A word: it does not start inside another word ("xses_a" is not one). It goes on over letters, digits and `_`; a
  mark that ends the sentence after it is not part of it, since none of those characters is one.

## Refused

- A scheme of the toolkit's for the target (`word:ses_abc`): the handler would strip it again. The word is the target,
  and no web address looks like one.
- A pattern language (regular expressions): the need is a prefix; a pattern would be slower at every text read, and
  a program would write patterns that match too much.
- Per-call prefixes: every caller of `rich_links` and every Markdown document would pass them. The words of a program
  are the same everywhere in it.

## Subtle points

- The prefixes are read without a lock, from the threads that build runs: they are set once, before any text is read,
  and never changed after. `link_words_set` copies them.
