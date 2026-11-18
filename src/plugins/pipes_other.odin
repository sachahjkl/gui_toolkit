#+build !windows
package tk_plugins

import "core:os"

// (os.pipe sets close-on-exec on both ends here: a process started later gets none of them)
@(private)
pipe_not_inherited :: proc(f: ^os.File) {}
