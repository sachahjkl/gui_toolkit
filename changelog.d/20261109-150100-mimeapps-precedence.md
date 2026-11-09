type: Fixed

**"Open with" on Linux** follows the MIME Applications specification: a `mimeapps.list` removes associations only for its level and the ones after it (a system list no longer removes what the user added), `<desktop>-mimeapps.list` gives defaults, a type with no `[Default Applications]` entry gets its most preferred application as default, and a type comes before its parents. A link that loops under `applications/` no longer overflows the stack. What was read is cached until a file or folder read changes (under 1 ms a call, against 10 to 16 ms in a debug build).
