# About modal

`ui.about_modal` (`src/ui/about.odin`) shows a standard About dialog for any program built with `gui_toolkit`. The
intent is [src/md/features/about-modal.md](../src/md/features/about-modal.md).

## Usage

```odin
ui.about_modal("about", &app.about_open, {
	name         = "Plume",
	version      = "0.15.0",
	tagline      = "A focused writing workspace",
	licence      = "MIT",
	copyright    = "© 2026 Froment Software",
	icon         = lucide.FEATHER,
	on_whats_new = proc(user: rawptr) { open_whats_new((^App)(user)) },
	website_url  = "https://froment.software",
	releases_url = "https://froment.software/plume/changelog/",
	user         = app,
})
```

## API

| Symbol | Role |
|---|---|
| `about_modal(id, showing, info)` | Builds the modal while `showing^` is true. Closes on Escape, Close button, corner cross, or scrim click. |
| `About_Info` | Program metadata: `name`, `version`, `tagline`, `licence`, `copyright`, `logo` (`render.Texture`), `logo_draw` / `logo_user`, `icon` / `icon_font`, `on_whats_new` (primary in-app "What's new" action), `website_url`, `releases_url` (secondary "Online release notes"), `links`, `diagnostics` (shows "Copy diagnostics" when non-empty), `on_link` / `user`. |
| `About_Link` | A link button: `label`, `url`, optional `icon` (defaults to `lucide.EXTERNAL_LINK`). Opens via `on_link` or `ui.open(url, .Url)`. |
| `about_version_text(info)` | Formats the one-line version string copied by "Copy version". |
| `about_diagnostics_text(info)` | Formats the multi-line diagnostics text copied by "Copy diagnostics" (program version, `ui.VERSION`, Odin version, OS, licence, and `info.diagnostics`). |
