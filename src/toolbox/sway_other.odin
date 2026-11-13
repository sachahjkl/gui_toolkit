#+build !linux
package tk_toolbox

// The sway session of sway.odin is Linux's: elsewhere it does not start.

import "core:os"
import "core:time"

sway_start :: proc(s: ^Sway, dir: string, o := Sway_Options{}) -> (why: string) { return "a sway session runs on Linux only" }

sway_program :: proc(s: ^Sway, command: []string, env: []string = nil, log := "") -> (p: os.Process, why: string) { return {}, "no session" }

sway_wait :: proc(s: ^Sway, p: os.Process, limit: time.Duration) -> (state: os.Process_State, ended: bool) { return {}, false }

sway_stop :: proc(s: ^Sway) { s^ = {} }
