# The desktop's background

The code is `src/platform/wallpaper*.odin` and `src/ui/wallpaper.odin`; a program's author reads
[docs/platform.md](../../../docs/platform.md), "The desktop's background".

## Why

galerie's menu had "Set as wallpaper" refused: it waits for a call of the toolkit, not platform code of its own. A
viewer, a file manager and a camera's program all have the act.

## Decisions

- **Linux: the desktop portal only.** `org.freedesktop.portal.Wallpaper` is what GNOME's and KDE's portals answer,
  under a sandbox too. The picture goes as a descriptor (`SetWallpaperFile`), not a URI: a sandboxed portal may not
  see the program's paths. No preview (`show-preview` false): the person chose the act in the program already; the
  background only (`set-on`), not the lock screen. Refused: `gsettings`, `plasma-apply-wallpaperimage`,
  `feh` and the like, per desktop (a list that grows with every desktop, and none of them under a sandbox): a desktop
  without the portal is `.Unsupported`, and the program says so.
- **Windows: `SystemParametersInfoW(SPI_SETDESKWALLPAPER)`.** Every screen gets the picture, the profile keeps it,
  the windows that listen are told. Refused: `IDesktopWallpaper` (a picture per screen, which no program asked for,
  and a COM apartment on the worker).
- **A blocking call, on a worker.** A portal's request waits for its Response, and the person may be asked; Windows'
  broadcast can wait for a hung window. `ui.wallpaper_set` runs it on the chores and gives the result back at a
  build: the interface's thread never waits.
- **Four results, no words.** Set, Cancelled, Unsupported, Failed: the program says it in its own words (a toast, a
  greyed item).

## Tests

A test never calls the system for real: it would change the background of whoever runs it. `platform_pkg` checks a
file that cannot be read (Failed before any bus), a session with no bus (Unsupported) and the answer codes;
`scenarios` checks that the result comes back at a later build.
