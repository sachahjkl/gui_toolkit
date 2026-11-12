type: Changed

**Preferences can be written off the interface thread**: `config.serialize_user` builds the text of the user's file on the loop and `config.write_user_file` writes it on any thread, so a slow disk does not stop the interface; `config.save_user` does both at once, as before. `Prefs.user_version` replaces `Prefs.dirty`: it counts the changes of the user's layer, and a program saves when it differs from the version it last wrote.
