type: Added

**An install for everyone**: the install dialog and the Installation page offer "Only me" or "Everyone on this computer",
each with what it means on this system. For everyone, the program goes to Program Files (Windows) or `/opt` (Linux), its
menu entry, PATH and record are every account's, and an administrator allows it in one prompt (`runas`, `pkexec`).
Each account keeps its own desktop shortcut and start with the session. Choosing the other scope moves the install.
On NixOS the choice says that the Nix package is the install for everyone. `Setup_Options.scopes` lets a program stay
per person; `Facts.scope`, `Facts.other_scope`, `Facts.system_refusal` and `desktop.Scope` say the state. The
updater of a copy that its account cannot write is `Administered`: it downloads nothing and says that an administrator
updates it. On Windows, Uninstall of an install for everyone says that the program goes at the next restart.
