type: Added

**`desktop.file_icon` (the size its file is chosen by apart from the size made: `choose`), `file_icon_key`, `file_icon_destroy`, `svg_available`**: the system's icon of a file or a folder, as its file manager shows it: on Linux the person's icon theme (Icon Theme specification, the type from shared-mime-info, SVG files rendered by librsvg opened at run time), on Windows the shell's icon of the path.
  - `platform.cursor_resample` is now `platform.rgba_resample` (an icon theme's PNG files are reduced with it).
  - `platform.portal_icon_theme`: the icon theme the desktop shows, from the Settings portal (`org.gnome.desktop.interface` `icon-theme`); `file_icon` reads it before the GTK and KDE files.
