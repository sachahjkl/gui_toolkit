# site: a project's website

`src/site` (package `tk_site`; import it as `tk_site "<toolkit>/src/site"`, or `tk_site "gt:site"`) makes the pages of a
project's site from its own sources, and checks them in a real browser. The toolkit's site uses it (`tk site_build`), and so does
opencode native's (`occtools site build`). A project gives its names, address and colours (`Meta`), its home page as the template
(`site/index.html`), and its CHANGELOG.md.

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

## Markdown

`markdown_html(md, link)` converts the subset a project's documents use: headings (with GitHub's ids, `heading_id`),
paragraphs, `*emphasis*`, `**strong**`, `` `code` ``, fenced code, nested lists, tables, links and images. `link` (a
`Link_Rule`) says what a link's address becomes; `nil` keeps it. `markdown_title(md)` is the first `# ` heading. A construct
that is missing shows up as plain text. `tk site_docs` makes the toolkit's Docs pages with it.

## The check in a browser

`check(o)` makes the pages with `o.generate` into a temporary folder, serves them on 127.0.0.1, and drives Chrome or Edge with
no window over `src/cdp`:

- the image viewer of `gallery.js` on the home page and the classic screenshots: a click opens it, the picture loads at its
  size, the arrows go through the captures, Esc closes and gives the keyboard back to the link;
- every page: the links, pictures, styles and scripts on the site are there, and the anchors they point at; the home page and
  the changelog link their classic page, and back;
- the classic pages: a main, header, nav and footer, a text for every picture, a skip link that Tab reaches first, no sideways
  scrolling on a phone or a desktop, light and dark, a home page 1.5 screens high at most;
- then the project's own checks (`o.extra`), with `check_go`, `check_true`, `check_text`, `check_call`, `check_expect`.

`check_arguments` reads `--site folder`, `--shot file.png` and `--browser program`. What the browser leaves (its processes,
its profile) is removed, and a run that cannot remove it fails.

## Tests

`src/site/site_test.odin` (the changelog, the classic links, what a page says when shared), `check_test.odin` (the files the
server gives and refuses, the links and anchors, the browser's port file), `markdown_test.odin`.
