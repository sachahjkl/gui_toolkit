type: Fixed

**A program built by the toolkit starts on Windows again**: the application manifest the builder writes gave the program's own version (0.21.0.0) and the architecture "*" as its assembly's identity, and Windows refused to start it (error 14001). The identity is now version 1.0.0.0 on amd64, as Wren's; the program's version stays in its VERSIONINFO.
