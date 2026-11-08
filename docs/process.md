# process: what a program knows of its own process

`import process "gt:process"` (or the relative path of the submodule). The package is named `tk_process`. Pure Odin and the
system's own calls, any target.

```odin
args := process.command_line_args()     // the arguments without the program's name, as UTF-8
exe := process.executable_path()        // "" when the system cannot say
dir := process.parent_dir(exe)          // "" when the path has no folder; '\' and '/' both separate
process.console_write("done\n")         // the standard output
process.console_error("failed\n")       // the standard error output
```

On Windows `os.args` comes from the C runtime's narrow argv, in the system's ANSI code page: a path with a letter outside it
arrives damaged. `command_line_args` reads the UTF-16 command line instead.

A Windows program with a window has no console of its own. `console_write` writes to the standard output when the parent gave
it one (a redirection to a file, a pipe), else to the console of the process that started it, attached once. A redirection
is never bypassed.
