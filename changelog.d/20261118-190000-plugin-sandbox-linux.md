type: Security

**A plugin's process is isolated by the system on Linux**: before the plugin's code runs, its process takes away its
own access to every file (Landlock), every socket (a seccomp filter) and, on recent kernels, its signals to other
processes. It reads its modules before that, and the program writes its log. `Host_Options.sandbox` (`If_Available` by
default, `Required`, `Off`) says what happens where the kernel has no Landlock; `plugins.sandbox_available` says
whether this system can, and `plugins.test_escape` lets a test check it.
