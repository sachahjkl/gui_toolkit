#+build !windows
package tk_process

import "core:os"

// The standard output (a program with a terminal has one).
console_write :: proc(text: string) { _, _ = os.write_string(os.stdout, text) }

// The standard error output.
console_error :: proc(text: string) { _, _ = os.write_string(os.stderr, text) }
