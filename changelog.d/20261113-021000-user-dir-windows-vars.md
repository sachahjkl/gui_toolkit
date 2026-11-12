type: Fixed

**`platform.user_dir` follows `%APPDATA%` and `%LOCALAPPDATA%` on Windows**: an absolute variable is taken, as XDG's are on Linux, so a test or a portable copy that points them elsewhere is followed; without them, the known folders.
