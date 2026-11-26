#+build !windows
package tk_desktop

// No system's task manager to take the place of here (src/md/features/default-task-manager.md, "Linux: no part"): the
// backends have no Task_Manager part, and the elevated command has nothing to change.
task_manager_write :: proc(o: ^Integration_Options, on: bool) -> Result { return {.Unsupported, error_text(.Unsupported)} }

// No machine copy here.
task_manager_copy :: proc(o: ^Integration_Options) -> string { return "" }
