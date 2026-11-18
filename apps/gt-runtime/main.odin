// gt-runtime: one plugin run as an application (app/app.odin says what it is).
//
//   gt-runtime <folder>       a plugin's folder (its plugin.json and its files)
//   gt-runtime <main.js>      a lone file: its manifest is implied (its name, one view "main")
package gt_runtime

import "core:fmt"
import "core:os"
import host "gt:host"
import "gt:platform"
import runtime_app "app"

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "--help" || os.args[1] == "-h" {
		fmt.eprintln("gt-runtime <folder or main.js>: runs one plugin as an application")
		os.exit(len(os.args) < 2 ? 2 : 0)
	}
	app := runtime_app.open({path = os.args[1]})
	if app == nil { os.exit(1) }
	defer runtime_app.close(app)
	platform.show_window(app.main.win)
	for !platform.is_closed(app.main.win) {
		host.hosts_wait({&app.main})
		runtime_app.frame(app)
	}
}
