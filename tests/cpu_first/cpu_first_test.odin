// The CPU stage's rasteriser against the GPU (src/md/infrastructure/cpu-first-frames.md): fidget's first screens drawn
// offscreen on the software Vulkan device, and the same frames drawn on the CPU (TOOLKIT_CPU_SHADOW=1). Linux: the
// stage is Linux's.
//   odin run tools/run_tests -- cpu_first
// CPU_FIRST_SHOTS=<folder>: the pictures there (a failure leaves them in build/cpu_first).
package cpu_first_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../../examples/fidget"
import png "gt:png"
import "gt:render"
import "gt:testkit"

// A pixel differs when a channel differs by more than this (8 bits): the GPU encodes to sRGB after each blend, the CPU
// once, and their antialiased edges round apart.
@(private = "file") PIXEL_TOLERANCE :: 6
// The share of pixels that may differ (the edges of curves and of text, where the two round apart most). Measured: 2
// pixels of 920 400 on the Controls page.
@(private = "file") MAX_SHARE :: 0.001
// The mean difference of a channel over the whole picture, in steps of 8 bits. Measured: 0.004.
@(private = "file") MAX_MEAN :: 0.05

// What two RGBA8 pictures of the same size differ by.
@(private = "file")
Difference :: struct { over: int, largest: int, mean: f64 }

@(private = "file")
difference :: proc(a, b: []u8) -> (d: Difference) {
	sum: f64
	for i := 0; i + 3 < len(a) && i + 3 < len(b); i += 4 {
		worst := 0
		for k in 0 ..< 4 {
			v := abs(int(a[i + k]) - int(b[i + k]))
			worst = max(worst, v)
			sum += f64(v)
		}
		d.largest = max(d.largest, worst)
		if worst > PIXEL_TOLERANCE { d.over += 1 }
	}
	d.mean = sum / f64(max(len(a), 1))
	return
}

// fidget opened with `args`, two frames, its GPU picture against its CPU one.
@(private = "file")
expect_same_picture :: proc(t: ^testing.T, name: string, args: []string, loc := #caller_location) {
	os.set_env("TOOLKIT_CPU_SHADOW", "1")
	defer os.unset_env("TOOLKIT_CPU_SHADOW")
	dir := testkit.temp_folder(t, "cpu_first")
	// (fidget keeps tables for the process, as tests/examples opens it: not the test's own allocator)
	context.allocator = runtime.heap_allocator()
	app := fidget.open({args = args, headless = true, settings_dir = dir})
	if !testing.expect(t, app != nil, "fidget opens", loc = loc) { return }
	defer fidget.close(app)
	// (the second frame: the first one's text and pictures have settled)
	fidget.frame(app)
	fidget.frame(app)
	gpu := render.read_pixels(&app.r)
	defer delete(gpu)
	cpu := render.cpu_shadow_pixels(&app.r)
	defer delete(cpu)
	if !testing.expect(t, gpu != nil && cpu != nil && len(gpu) == len(cpu), "both pictures", loc = loc) { return }
	size := app.r.size
	d := difference(gpu, cpu)
	share := f64(d.over) / f64(size.x * size.y)
	ok := share <= MAX_SHARE && d.mean <= MAX_MEAN
	exact := render.cpu_frame_exact(&app.r)
	fmt.printfln("cpu_first %s: %dx%d, %d pixels (%.4f %%) differ by more than %d, the largest by %d, a channel by %.4f on average, exact: %v",
		name, size.x, size.y, d.over, share * 100, PIXEL_TOLERANCE, d.largest, d.mean, exact)
	shots := os.get_env("CPU_FIRST_SHOTS", context.temp_allocator)
	if shots == "" && !ok { shots = "build/cpu_first" }
	if shots != "" {
		_ = os.make_directory_all(shots)
		for pic in ([][2]string{{"gpu", ""}, {"cpu", "cpu"}}) {
			data := pic[1] == "" ? gpu : cpu
			path, _ := filepath.join({shots, strings.concatenate({name, "_", pic[0], ".png"}, context.temp_allocator)}, context.temp_allocator)
			_ = os.write_entire_file(path, png.encode(data, size.x, size.y, allocator = context.temp_allocator))
		}
		fmt.printfln("cpu_first %s: the pictures are in %s", name, shots)
	}
	testing.expectf(t, ok, "%s: the CPU's picture is the GPU's: %d pixels (%.3f %%) differ by more than %d, the largest by %d, a channel by %.3f on average",
		name, d.over, share * 100, PIXEL_TOLERANCE, d.largest, d.mean, loc = loc)
	// (these pages draw no layer, filter or picture: the CPU draws all of them)
	testing.expectf(t, exact, "%s: the CPU drew everything", name, loc = loc)
}

@(test)
controls_on_the_cpu_are_the_gpus :: proc(t: ^testing.T) {
	expect_same_picture(t, "controls", {"--anim=off"})
}

@(test)
inputs_on_the_cpu_are_the_gpus :: proc(t: ^testing.T) {
	expect_same_picture(t, "inputs", {"--anim=off", "--page=1"})
}

// Blended in sRGB values, as browsers do: the other path of every formula.
@(test)
srgb_blending_on_the_cpu_is_the_gpus :: proc(t: ^testing.T) {
	expect_same_picture(t, "srgb", {"--anim=off", "--blending=srgb"})
}

// Another palette: light, other radii, other gradients.
@(test)
another_palette_on_the_cpu_is_the_gpus :: proc(t: ^testing.T) {
	expect_same_picture(t, "palette", {"--anim=off", "--theme=3"})
}
