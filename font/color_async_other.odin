#+build !windows
package font

// Asynchronous color-glyph drawing (color_async.odin) is a Windows / DirectWrite path: a background thread draws COLR v1
// and bitmap-emoji glyphs into the atlas while the frame goes on. The non-Windows backend does not draw color glyphs on
// a thread of its own (Settings.color_async is ignored off Windows, defaulting off), so these are the neutral no-ops that
// keep the public API the same on every system: there is never a pending color glyph, so the ready generation never
// moves and a picture is never stale for one. An application's ready callback is accepted and simply never called.

set_color_ready_callback :: proc(s: ^State, fn: proc(user: rawptr), user: rawptr) {}

// Color glyph requests finished so far: a constant here (nothing is queued), so a picture's "pending at this generation"
// check never reports it stale.
color_ready_generation :: proc(s: ^State) -> u64 { return 0 }

// Color glyphs queued or being drawn: none off Windows.
color_pending :: proc(s: ^State) -> int { return 0 }

// Waits until every queued color glyph is in the atlas: nothing is queued, so this returns at once.
color_wait :: proc(s: ^State) {}
