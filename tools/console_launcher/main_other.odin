#+build !windows
// console_launcher: Windows only (a program of the Windows subsystem has no console; elsewhere a program has the
// terminal's). main.odin has the launcher.
package console_launcher

import "core:fmt"
import "core:os"

main :: proc() {
	fmt.eprintln("console_launcher: a Windows program (Windows programs with a window have no console; elsewhere there is nothing to launch)")
	os.exit(1)
}
