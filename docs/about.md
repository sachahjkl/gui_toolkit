# About modal

`ui.about_modal` (`src/ui/about.odin`) shows a standard About dialog for any program built with `gui_toolkit`. The
intent is [src/md/features/about-modal.md](../src/md/features/about-modal.md).

## Usage

```odin
ui.about_modal("about", &app.about_open, {
	name      = "Plume",
	version   = "0.15.0",
	tagline   = "A fast native Markdown editor",
	licence   = "MIT",
	copyright = "© 2026 Froment Software",
	icon      = lucide.FEATHER,
	links     = {
		{label = "Website", url = "https://froment.software"},
		{label = "Repository", url = "https://github.com/sachahjkl/plume"},
	},
})
```

## API

| Symbol | Role |
|---|---|
| `about_modal(id, showing, info)` | Builds the modal while `showing^` is true. Closes on Escape, Close button, corner cross, or scrim click. |
| `About_Info` | Program metadata: `name`, `version`, `tagline`, `licence`, `copyright`, `logo` (`render.Texture`), `logo_draw` / `logo_user`, `icon` / `icon_font`, `links`, `diagnostics`, `on_link` / `user`. |
| `About_Link` | A link button: `label`, `url`, optional `icon` (defaults to `lucide.EXTERNAL_LINK`). Opens via `on_link` or `ui.open(url, .Url)`. |
| `about_version_text(info)` | Formats the one-line version string copied by "Copy version". |
| `about_diagnostics_text(info)` | Formats the multi-line diagnostics text copied by "Copy diagnostics" (program version, `ui.VERSION`, Odin version, OS, licence, and `info.diagnostics`). |
