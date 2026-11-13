type: Added

**`toolbox.tool_main`**: a project's tool is a list of `toolbox.Command`s. It says the help, refuses an unknown command or a line a command does not take with exit code 2, joins the `-name:value` flags that PowerShell splits, and works from the project's root, found by its mark. `tk` and every program's tool use the same dispatcher.
