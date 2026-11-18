type: Security

**A plugin's process is isolated on Windows too.** It runs in an AppContainer with no capability: it reaches none of
the person's files and no network, only the two pipes it talks to the program through. `Host_Options.sandbox` decides,
as on Linux: `If_Available`, `Required` or `Off`.
