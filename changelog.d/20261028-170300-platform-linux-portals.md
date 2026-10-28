type: Added

**Linux file dialogs, open-URL and live theme through the XDG portals** (`platform`): `open_file_dialog` / `save_file_dialog` / `pick_folder_dialog` now use `org.freedesktop.portal.FileChooser` first (filters, multiple selection, a suggested name; it works under a sandbox), falling back to zenity / kdialog; `open_url` / `open_path` use `org.freedesktop.portal.OpenURI`; `dark_mode_preferred` reads the appearance portal's `color-scheme` and the new `watch_color_scheme(cb)` reports a live light / dark switch (the `SettingChanged` signal).
