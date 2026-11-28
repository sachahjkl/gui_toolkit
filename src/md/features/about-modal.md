# Generic About modal

`ui.about_modal` (`src/ui/about.odin`) gives every program one standard About dialog built on `ui.modal`: logo or icon,
program name, tagline, version, toolkit version (`ui.VERSION`), licence, copyright, clickable links, and copy buttons
for version and diagnostics. A program's author reads [docs/about.md](../../../docs/about.md).

## Decisions

- **In `gt:ui`, not `gt:prefs_page`.** Every program imports `gt:ui`; a small program or example does not need the
  settings page package to show an About dialog, and `ui` already owns `modal`, `VERSION`, `open`, clipboard
  access, icons, and toasts.
- **No duplicate header strip.** `about_modal` uses `modal`'s top-right corner close cross without a separate title
  bar so the program name appears once in the hero row (Interface Design: say each piece of information once).
- **Pure text formatters.** `about_version_text` and `about_diagnostics_text` build the copied strings separately from
  the UI so tests and programs can reuse or assert the exact text without scraping boxes.
- **Non-blocking links.** Link buttons call `About_Info.on_link` when provided, otherwise `ui.open(url, .Url)` on the
  chores pool, never blocking the interface thread.
- **Zero globals.** All state belongs to the caller's `open: ^bool` and `ui.State`.

## Refused

- **A program-specific About view in each app.** Each program duplicated layout, version strings, and clipboard code.
- **Reading GPU or OS diagnostics synchronously inside the modal.** If a program wants hardware or renderer lines in
  "Copy diagnostics", it passes them through `About_Info.diagnostics` from data it already holds.
