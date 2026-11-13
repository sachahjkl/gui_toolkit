#+build !windows
#+build !linux
package tk_ocr

@(private) system_available :: proc() -> (engine: Engine, ok: bool) { return .None, false }
@(private) system_max_side :: proc() -> int { return 0 }
@(private) system_languages :: proc(allocator := context.allocator) -> []string { return nil }

@(private)
system_recognize :: proc(p: Prepared, o: Recognize_Options, lines: ^[dynamic]Line, allocator := context.allocator) -> (engine: Engine, language: string, err: Error) {
	return .None, "", .No_Engine
}
