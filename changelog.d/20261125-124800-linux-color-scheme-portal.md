type: Fixed

**Linux desktop light/dark detection (`platform.dark_mode_preferred`, `platform.watch_color_scheme`)**: treat an XDG Settings portal `org.freedesktop.appearance` `color-scheme` of `0` (no preference, which GNOME and `xdg-desktop-portal-gtk` report for light mode) as light instead of falling through to stale GTK 3 settings, fall back to `Read` when `ReadOne` is unavailable, reject malformed non-integer portal replies, and keep internal `color_scheme_serial` tracking independent from an application's `watch_color_scheme` callback so neither overwrites the other.
