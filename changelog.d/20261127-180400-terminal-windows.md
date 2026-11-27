type: Security

**`desktop.open_terminal` on Windows no longer reads the folder's name as a command.** Windows Terminal took a `;` in the folder's path as the start of another of its commands, and both terminals were looked for in the folder opened first, where a planted `wt.exe` or `cmd.exe` would run. The folder is now the terminal's starting folder, never a word of its command line, and each program is found by its whole path (`PATH`, the system's folder). On Linux the folder is passed after `--`.
