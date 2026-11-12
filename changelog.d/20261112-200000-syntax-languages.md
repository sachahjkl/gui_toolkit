type: Added

**`gt:syntax` knows more languages, and Markdown and diffs**: Java, C#, Kotlin, Swift, Dart, PHP, Ruby, Lua, Zig, Nix,
YAML, TOML, INI, Dockerfile and Makefile are coloured; HTML, XML and CSS are coloured now (tags, attributes, selectors,
properties). `language_of_file` finds `Dockerfile` and `Makefile` by their whole name, and `guess` finds every one of
these in a pasted text, and says when a text is Markdown or a diff (`highlight = false`: the label, no colours).
