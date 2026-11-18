type: Added

**A plugin's permissions, files, network and clipboard (plugin API level 4)**: a manifest asks for `permissions`
(`files`, `folder:documents`, `folder:downloads`, `net:*` or `net:<origin>`, `clipboard.read`, `clipboard.write`); a
plugin that asks is off until the person allows it in a dialog that says each one in words, and a version that asks
more asks again. `files.read`, `files.write`, `files.pick`, `http.fetch`, `clipboard.read` and `clipboard.write` are
done by the program, which checks the grant: a call without it rejects with `PermissionError`, a path that leaves its
folder or goes through a link is refused, each redirect is checked, and the clipboard is read only while the person acts
in the plugin. Each plugin has a data folder of its own. `plugins.grant` and `plugins.revoke` give and take back.
