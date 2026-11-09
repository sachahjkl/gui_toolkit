# site: a project's website

`src/site` (package `tk_site`; import it as `tk_site "<toolkit>/src/site"`, or `tk_site "gt:site"`) makes the pages of a
project's site from its own sources, and checks them in a real browser. The toolkit's site uses it (`tk site_build`), so do
opencode native's (`ocntools site build`) and Wren's documentation (its `docsite` tool). A project gives its names, address and
colours (`Meta`, `Docs`), its home page as the template (`site/index.html`), its CHANGELOG.md and its documents (`docs/`).

## The changelog's pages

`build_changelog(site, out, {changes, version_mark})` copies the folder `site` to `out`, then writes:

- `index.html`: the home page, the last 3 versions in place of `<!-- whats-new -->` (`news_html`). `version_mark` (for example
  `{{version}}`) is replaced by the last version, so a download link can name the files of that release.
- `changelog.html`: every version, the last 6 open, with a filter. It wears the home page's head, bar, footer and first script.
- `classic/`: the same in a classic presentation (`index.html`, `features.html`, `screenshots.html`, `changelog.html`), a line
  of plain links and a column of text, with `classic/classic.css` of the site. Each modern page's footer links its classic page
  ("Classic version"), each classic page the modern one ("Modern version").

CHANGELOG.md follows Keep a Changelog: `## [x.y.z] - date`, `### Added`..., `[x.y.z]: url` at the end. The home page must hold
these parts, or the step says which one is missing: `<!-- whats-new -->`, `<a href="classic/">Classic version</a>` in its
footer, a `hero` section (its `h1`, its logo `img.mark`, its `.actions` and `p.small`), `figure.shot.wide`, `section.gallery`,
a `download` section, a `features` section of `article.card` items, a `nav#nav`.

The pages were first made by JavaScript and were compared with these byte for byte. The parts that read text say which regular
expression they match, with what JavaScript gives its whitespace, `.`, UTF-16 lengths and `$` in a replacement (`html.odin`).

## What a page says when shared

`build_meta(m, from, out)` gives each page of `out` its canonical address, its Open Graph and Twitter tags from its own title
and description, and the home page its structured data (`m.ld_type`, `m.ld_fields`). A redirect or a page marked `noindex` is
left alone. It writes `feed.xml` (Atom, the last 30 versions), `sitemap.xml`, `site.webmanifest`, `llms.txt`, a `404.html`
when there is none, and with `m.root_domain` also `robots.txt` and `favicon.ico`. The sharing card (`m.card`) must be there:
`draw_card(m, site)` draws it once, by hand, in a local Chromium (`CHROME`, or the usual places).

## The documentation pages

`build_docs(&d)` makes a page of each Markdown document of `d.source` (the repository's `docs/`) in `d.out` (the site's `docs/`):
a document `cdp.md` is the page `cdp/index.html`, at the address `/docs/cdp/`. Every page has the site's header (`d.header`) and footer
(`d.footer`), and:

- a menu of every page: open beside the page on a wide screen, folded under a "Documentation" toggle at 860 px and less (a
  checkbox: no script), with a search box, the sections, and the groups as `<details>` (open around the page shown);
- a breadcrumb (Docs, the section, the page), the previous and next pages in the menu's order, an "On this page" table of the
  headings of levels 2 and 3 (from 2 of them, beside the page from 1180 px), and "Edit this page on GitHub"
  (`d.repository`, `d.branch`);
- `docs.css` (`docs_css(d.css)`), `search.js` (`search_js`) and `search-index.json` (`search_index_json`: each page's address,
  title, section and the first `SEARCH_TEXT_MAX` bytes of its text). The search needs no server.

The menu is `docs/_nav.txt`:

```
# a comment
Section
  page.md  Label     a page of the section; without a label, its first heading
  dir/*    Label     every document of the folder, as a group; its README.md or index.md first, as "Overview"
```

A document that no line names goes to a last section, "More". A path that starts with `_` is not a document. Without an
`index.md` of its own, the documentation's home (`docs/index.html`) lists the pages by section.

What `Docs` gives besides: `name` (titles say "<page> · <name> docs"), `note` (the first line of every page: a comment that names
`writer.tool`), `head` (the icon, the style sheets), `expand` (the project's directives in a document), `rendered` (called after
each page: a second presentation of it), `assets` (folders of `docs/` copied beside the pages, linked there: pictures), `languages`
(the project's code languages), and `moved` (each page also at its old address `docs/<name>.html`, a page that sends the reader on,
its canonical address under `site_url`). Every address given is root-absolute ("/img/logo.png"); `site_relative` makes each
relative to its page, as a site served under a path of its own needs. `rooted` does the reverse for a piece of a page.

A link of a document is resolved from its folder: another document is its page (its `#anchor` kept), a file of an asset folder is
its copy, `../site/<page>/index.html` is that page of the site, and any other file of the repository is its page on GitHub. An
address with a scheme stays.

The style sheet lays over the site's own. It reads the site's colours under these names: `--bg`, `--surface`, `--surface-2`,
`--line`, `--line-2`, `--text`, `--muted`, `--soft`, `--accent`, `--accent-dim`. `Docs_Css` gives its first line (`note`), the
height of the site's top bar (`bar`, in px), the project's colours (`theme`) and its own rules (`extra`, before the narrow-screen
rules). `DOCS_CODE_CSS` styles the code blocks, their colours, the tables and the skip link, for a site whose style sheet has none:
a code block and a table scroll sideways in their frame.

The pages are written through a `Writer` (`write_generated`): a file is written only when its bytes change, and with
`writer.check` nothing is written and each file out of date is counted in `writer.problems`: a check that committed pages are up
to date. `prune_generated` removes the pages the tool made (its name in their first 300 bytes) that nothing makes any more.

## Markdown

`render_markdown(source, &ctx)` gives the HTML of a document, its headings (`Heading`: level, text, unique `id`) and its plain
text. It reads ATX headings (GitHub's ids, `heading_id`, each with its `#` anchor), paragraphs, hard breaks (two trailing
spaces), `*emphasis*` and `_emphasis_` (not inside a word: `gui_toolkit`), `**strong**`, `` `code` ``, links with a title,
pictures, `<autolinks>`, entities, backslash escapes, fenced code (` ``` ` or `~~~`), nested lists, blockquotes, thematic
breaks, tables (aligned, in a `div.table-box`; a `|` in a code span does not split a cell) and HTML blocks that start with a
known tag (copied). `Markdown_Context.link` says what a link's address becomes (`""`: as written). `markdown_title(md)` is the
plain text of the first `# ` heading. A construct it does not read shows up as text.

A code block is coloured when the page is made (`write_code_block`, `highlight`): `.k` keyword, `.s` string, `.c` comment, `.f`
call or directive, `.t` type or number. `CODE_LANGUAGES` has Odin, C, JavaScript, PowerShell, JSON and Rust, and labels for
HTML, CSS and shell; a project adds its own `Code_Language` (Wren: WIDL), looked at first. A language it does not know is plain.

## The links of a built site

`check_links(root, rules)` reads every page under `root` (no browser): each `href` and `src`, resolved from the page's folder,
must name a file there, and a `#fragment` an id of that page. A link that starts with `/` or climbs out of the site is wrong.
`Link_Rules.not_files` lists the starts of addresses that are not files (Wren's `wren-https:`); with `folders`, a page is linked
by its folder, never by its `.html`. It returns what is wrong, sorted, and the number of pages. `tk site_build` runs it on what
it made.

## The check in a browser

`check(o)` makes the pages with `o.generate` into a temporary folder, serves them on 127.0.0.1, and drives Chrome or Edge with
no window over `src/cdp`:

- the image viewer of `gallery.js` on the home page and the classic screenshots: a click opens it, the picture loads at its
  size, the arrows go through the captures, Esc closes and gives the keyboard back to the link;
- every page: the links, pictures, styles and scripts on the site are there, and the anchors they point at; the home page and
  the changelog link their classic page, and back;
- the classic pages: a main, header, nav and footer, a text for every picture, a skip link that Tab reaches first, no sideways
  scrolling on a phone or a desktop, light and dark, a home page 1.5 screens high at most;
- the documentation pages (`build_docs`): nothing sticks out of a 390 px screen but inside a code block's or a table's frame,
  the menu is closed there and beside the page at 1400 px; on `docs/index.html`, the toggle opens the menu and the search finds
  pages. A page left at an old address (a refresh) is not opened;
- then the project's own checks (`o.extra`), with `check_go`, `check_true`, `check_text`, `check_call`, `check_expect`.

`check_arguments` reads `--site folder`, `--shot file.png` and `--browser program`. What the browser leaves (its processes,
its profile) is removed, and a run that cannot remove it fails.

## Tests

`src/site/site_test.odin` (the changelog, the classic links, what a page says when shared), `check_test.odin` (the files the
server gives and refuses, the links and anchors, the browser's port file), `markdown_test.odin` (the Markdown and the colours of
code), `docs_test.odin` (a documentation site made end to end in a scratch folder, checked again, its links read back).
