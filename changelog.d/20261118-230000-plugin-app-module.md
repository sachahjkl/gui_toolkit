type: Added

**A program's own plugin module, `from "app"`**: a program declares its calls, events and permissions with structs in
`Host_Options.app` (`plugins.App_Module`), with a level of its own; a plugin calls them as promises with one argument
object, hears the events with `on(name, f)`, and asks for `app:` permissions shown in the program's words. A call runs
on the program's interface thread and may answer later (`plugins.app_answer`, `plugins.app_fail`);
`plugins.app_emit` sends an event to the running plugins that listen. `plugin_api.app_module_dts` and
`app_module_markdown` write the module's `app.d.ts` and reference page, and `toolbox.generated_files` writes or checks
a tool's generated files. A manifest's `"app": n` says the level it needs; gt-runtime gives no module `"app"`.
