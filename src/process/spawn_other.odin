#+build !linux
#+build !windows
package tk_process

// Elsewhere (macOS, the BSDs): os.process_start's own search and spawn.

import "core:os"

@(private)
resolve :: proc(name: string, env: []string) -> (path: string, ok: bool) { return name, name != "" }

@(private)
spawn :: proc(desc: os.Process_Desc, resolved: string) -> (p: os.Process, err: os.Error) { return os.process_start(desc) }
