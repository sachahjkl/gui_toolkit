type: Added

**`platform.Clipboard_Content.files_cut`, `platform.clipboard_files_cut`**: files cut on the clipboard, for a move, as file managers do it. Windows writes and reads `Preferred DropEffect` = move. Linux also offers `x-special/gnome-copied-files` (`copy` or `cut`, then the URIs) and, for a cut, `application/x-kde-cutselection`; it reads the cut from either. Pure helpers: `gnome_copied_files_encode`, `clipboard_files_cut_decode`.
