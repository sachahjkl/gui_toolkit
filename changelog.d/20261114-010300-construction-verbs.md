type: Changed

**Construction verbs**: `_make` returns a new value, `_init` makes one in place, `_start` and `_stop` are for what owns a thread. So `flowgraph.run_start` becomes `flowgraph.run_init`, and `prefs_page.themes_file_make` (which writes the template file) becomes `themes_file_write_template`.
