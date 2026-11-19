type: Added

**`Project.native_carried` and `Project.systems`**: a program whose own Rust library carries the toolkit's native crates
sets `native_carried`, and `build_native` then builds none of the toolkit's library (`native_parts`): only the Windows
resource, the console launcher and the Lucide subset. `systems` names the systems the program is built for (`{}`:
Windows, Linux and macOS, as before): `check` checks only those other systems (`project_systems`).
