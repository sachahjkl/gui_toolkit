type: Fixed

**A program built by the toolkit starts on Windows again, for real this time**: 0.252.1 changed only the manifest's identity, and Windows still refused to start the programs (error 14001). The manifest the builder writes is now, word for word, the one papier and Wren started with: version 1.0.0.0 on amd64, run as the user, Windows 10 and 11, per-monitor DPI. The dependency on Common Controls 6, `longPathAware` and the UTF-8 code page are gone: nothing in the toolkit needs them.
