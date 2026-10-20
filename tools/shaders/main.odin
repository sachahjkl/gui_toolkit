// Compiles the renderer's HLSL to the DXBC blobs it embeds (render/shaders/*.dxbc).
//   odin run tools/shaders            write the blobs that differ from their sources
//   odin run tools/shaders -- -check  only compare (exit code 1 when a blob is stale)
// Run it after editing render/rect.hlsl or render/filter.hlsl; tests/shaders fails until then.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:time"
import "../../render"

main :: proc() {
	check := len(os.args) > 1 && os.args[1] == "-check"
	dir, _ := filepath.join({filepath.dir(#file), "..", "..", "render", "shaders"})
	stale := 0
	for d, id in render.SHADERS {
		t0 := time.tick_now()
		code, ok := render.shader_compile(id)
		if !ok {
			fmt.eprintln("shaders:", d.name, d.entry, "does not compile")
			os.exit(1)
		}
		ms := time.duration_milliseconds(time.tick_since(t0))
		if slice.equal(code, d.blob) {
			fmt.printfln("%s up to date (%d bytes, compiled in %.1f ms)", d.file, len(code), ms)
			continue
		}
		stale += 1
		if check {
			fmt.printfln("%s is stale", d.file)
			continue
		}
		path, _ := filepath.join({dir, d.file})
		if err := os.write_entire_file(path, code); err != nil {
			fmt.eprintln("shaders: cannot write", path, err)
			os.exit(1)
		}
		fmt.printfln("%s written (%d bytes, compiled in %.1f ms)", d.file, len(code), ms)
	}
	if check && stale > 0 { os.exit(1) }
}
