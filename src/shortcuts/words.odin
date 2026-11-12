package tk_shortcuts

// What a settings page says of a shortcut, plainly: the same words in every program (gt:prefs_page shows them under a
// shortcut's line). Pure: `asked` is the keys the program asked for (its preference, as platform.hotkey_parse reads it;
// "": none), `st` what the system said (status).

import "core:fmt"
import "core:strings"
import "../ascii"
import "../platform"

// The state in words, for the weak line under the shortcut ("": nothing to say).
status_text :: proc(asked: string, st: Status, allocator := context.temp_allocator) -> string {
	#partial switch st.state {
	case .Waiting:
		if asked == "" { return "" }
		return strings.clone("Waiting for the system's answer…", allocator)
	case .Bound:
		if asked == "" || same_keys(asked, st.trigger) { return fmt.aprintf("Works in every program: %s.", st.trigger, allocator = allocator) }
		return fmt.aprintf("The system gave other keys: %s. Change them in its shortcut settings.", st.trigger, allocator = allocator)
	case .No_Keys:
		if asked == "" { return strings.clone("No keys.", allocator) }
		return strings.clone("The system gave no keys yet: choose them in its shortcut settings.", allocator)
	}
	return ""
}

// What went wrong, for the red line under the shortcut ("": nothing).
problem_text :: proc(asked: string, st: Status, allocator := context.temp_allocator) -> string {
	if asked != "" {
		if _, parsed := platform.hotkey_parse(asked); !parsed {
			return fmt.aprintf("%q is not a shortcut: click the field and press the keys.", asked, allocator = allocator)
		}
	}
	#partial switch st.state {
	case .Taken:   return fmt.aprintf("Another program holds %s: choose other keys.", st.trigger, allocator = allocator)
	case .Refused: return strings.clone("The system refused this shortcut.", allocator)
	case .Unavailable:
		if asked == "" { return "" }
		return strings.clone("This desktop gives programs no shortcuts of their own: bind the keys in its own settings.", allocator)
	}
	return ""
}

// The same keys, whatever the words: "Ctrl+Shift+4" and "CTRL+SHIFT+4", the portal's "Shift+Print".
same_keys :: proc(a, b: string) -> bool {
	ha, ok_a := platform.hotkey_parse(a)
	hb, ok_b := platform.hotkey_parse(b)
	if ok_a && ok_b { return ha == hb }
	return ascii.equal_fold(a, b)   // (key names are ASCII)
}
