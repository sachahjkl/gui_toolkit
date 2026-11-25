// Differential, guard-byte, extreme-value, and opt-in benchmark tests for gt:h264 colour conversion.
// Run tests:
//   odin test tests/h264 -collection:gt=src -vet
//   odin test tests/h264 -collection:gt=src -vet -define:GT_H264_NO_AVX2=true
// Run opt-in benchmark:
//   odin test tests/h264 -collection:gt=src -o:speed -define:H264_BENCH=true -define:ODIN_TEST_NAMES=convert_bench
package h264_test

import "core:fmt"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import h264 "gt:h264"

@(private = "file") H264_BENCH :: #config(H264_BENCH, false)

// Verbatim scalar reference of the pre-SIMD converter (BT.709 limited range, 2x2 chroma mean).
@(private = "file") REF_Y_R :: 11966
@(private = "file") REF_Y_G :: 40254
@(private = "file") REF_Y_B :: 4064
@(private = "file") REF_CB_R :: -6596
@(private = "file") REF_CB_G :: -22189
@(private = "file") REF_CB_B :: 28785
@(private = "file") REF_CR_R :: 28785
@(private = "file") REF_CR_G :: -26145
@(private = "file") REF_CR_B :: -2640

@(private = "file")
ref_luma_of :: #force_inline proc "contextless" (r, g, b: i32) -> u8 {
	return u8(16 + ((REF_Y_R * r + REF_Y_G * g + REF_Y_B * b + 1 << 15) >> 16))
}

@(private = "file")
ref_chroma_of :: #force_inline proc "contextless" (r4, g4, b4: i32) -> (cb, cr: u8) {
	cb = u8(128 + ((REF_CB_R * r4 + REF_CB_G * g4 + REF_CB_B * b4 + 1 << 17) >> 18))
	cr = u8(128 + ((REF_CR_R * r4 + REF_CR_G * g4 + REF_CR_B * b4 + 1 << 17) >> 18))
	return
}

@(private = "file")
ref_convert :: proc(frame: h264.Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int, step: int) {
	r_at, b_at := 2, 0
	if frame.format == .RGBA { r_at, b_at = 0, 2 }
	width, height := h264.even_size(frame.width, frame.height)
	last_x, last_y := frame.width - 1, frame.height - 1
	for y := 0; y < height; y += 2 {
		row0 := frame.pixels[min(y, last_y) * frame.stride:]
		row1 := frame.pixels[min(y + 1, last_y) * frame.stride:]
		out0 := luma[y * luma_stride:]
		out1 := luma[(y + 1) * luma_stride:]
		chroma_row := (y / 2) * chroma_stride
		for x := 0; x < width; x += 2 {
			p0 := min(x, last_x) * 4
			p1 := min(x + 1, last_x) * 4
			r00, g00, b00 := i32(row0[p0 + r_at]), i32(row0[p0 + 1]), i32(row0[p0 + b_at])
			r01, g01, b01 := i32(row0[p1 + r_at]), i32(row0[p1 + 1]), i32(row0[p1 + b_at])
			r10, g10, b10 := i32(row1[p0 + r_at]), i32(row1[p0 + 1]), i32(row1[p0 + b_at])
			r11, g11, b11 := i32(row1[p1 + r_at]), i32(row1[p1 + 1]), i32(row1[p1 + b_at])
			out0[x] = ref_luma_of(r00, g00, b00)
			out0[x + 1] = ref_luma_of(r01, g01, b01)
			out1[x] = ref_luma_of(r10, g10, b10)
			out1[x + 1] = ref_luma_of(r11, g11, b11)
			u, v := ref_chroma_of(r00 + r01 + r10 + r11, g00 + g01 + g10 + g11, b00 + b01 + b10 + b11)
			at := chroma_row + (x / 2) * step
			cb[at] = u
			cr[at] = v
		}
	}
}

@(private = "file")
ref_to_nv12 :: proc(frame: h264.Frame, luma: []u8, luma_stride: int, chroma: []u8, chroma_stride: int) {
	ref_convert(frame, luma, luma_stride, chroma, chroma[1:], chroma_stride, 2)
}

@(private = "file")
ref_to_i420 :: proc(frame: h264.Frame, luma: []u8, luma_stride: int, cb, cr: []u8, chroma_stride: int) {
	ref_convert(frame, luma, luma_stride, cb, cr, chroma_stride, 1)
}

// SplitMix64 deterministic PRNG so fuzz frames are identical on every run and platform.
@(private = "file")
rng_next :: proc(state: ^u64) -> u64 {
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private = "file")
fill_random :: proc(buf: []u8, state: ^u64) {
	i := 0
	for ; i + 8 <= len(buf); i += 8 {
		v := rng_next(state)
		for k in 0 ..< 8 { buf[i + k] = u8(v >> uint(k * 8)) }
	}
	if i < len(buf) {
		v := rng_next(state)
		for k := 0; i < len(buf); i, k = i + 1, k + 1 { buf[i] = u8(v >> uint(k * 8)) }
	}
}

@(private = "file") GUARD_LEN :: 64
@(private = "file") GUARD_BYTE :: u8(0xA5)

@(private = "file")
make_guarded :: proc(size: int) -> (backing: []u8, view: []u8) {
	backing = make([]u8, size + 2 * GUARD_LEN)
	slice.fill(backing, GUARD_BYTE)
	view = backing[GUARD_LEN : GUARD_LEN + size]
	return
}

@(private = "file")
expect_guards_intact :: proc(t: ^testing.T, backing: []u8, label: string, loc := #caller_location) {
	for i in 0 ..< GUARD_LEN {
		if backing[i] != GUARD_BYTE {
			testing.expectf(t, false, "%s: leading guard byte %d modified: 0x%02x", label, i, backing[i], loc = loc)
			return
		}
	}
	tail_start := len(backing) - GUARD_LEN
	for i in tail_start ..< len(backing) {
		if backing[i] != GUARD_BYTE {
			testing.expectf(t, false, "%s: trailing guard byte %d modified: 0x%02x", label, i - tail_start, backing[i], loc = loc)
			return
		}
	}
}

// Compare h264.to_nv12 and h264.to_i420 byte for byte against the scalar reference, with guard bytes and stride padding.
@(private = "file")
check_frame_exact :: proc(
	t: ^testing.T,
	frame: h264.Frame,
	luma_pad, chroma_pad: int,
	label: string,
	loc := #caller_location,
) {
	even_w, even_h := h264.even_size(frame.width, frame.height)
	luma_stride := even_w + luma_pad
	luma_size := luma_stride * even_h

	// NV12 check (includes stride padding bytes: both reference and SIMD must leave them at GUARD_BYTE).
	nv12_chroma_stride := even_w + chroma_pad
	nv12_chroma_size := nv12_chroma_stride * (even_h / 2)

	got_y_buf, got_y := make_guarded(luma_size)
	defer delete(got_y_buf)
	ref_y_buf, ref_y := make_guarded(luma_size)
	defer delete(ref_y_buf)
	got_uv_buf, got_uv := make_guarded(nv12_chroma_size)
	defer delete(got_uv_buf)
	ref_uv_buf, ref_uv := make_guarded(nv12_chroma_size)
	defer delete(ref_uv_buf)

	h264.to_nv12(frame, got_y, luma_stride, got_uv, nv12_chroma_stride)
	ref_to_nv12(frame, ref_y, luma_stride, ref_uv, nv12_chroma_stride)

	expect_guards_intact(t, got_y_buf, "nv12 luma", loc)
	expect_guards_intact(t, got_uv_buf, "nv12 chroma", loc)
	if !slice.equal(got_y, ref_y) {
		for i in 0 ..< len(got_y) {
			if got_y[i] != ref_y[i] {
				testing.expectf(t, false, "%s NV12 luma mismatch at byte %d: got %d want %d", label, i, got_y[i], ref_y[i], loc = loc)
				break
			}
		}
	}
	if !slice.equal(got_uv, ref_uv) {
		for i in 0 ..< len(got_uv) {
			if got_uv[i] != ref_uv[i] {
				testing.expectf(t, false, "%s NV12 chroma mismatch at byte %d: got %d want %d", label, i, got_uv[i], ref_uv[i], loc = loc)
				break
			}
		}
	}

	// I420 check
	i420_chroma_stride := even_w / 2 + chroma_pad
	i420_chroma_size := i420_chroma_stride * (even_h / 2)

	slice.fill(got_y_buf, GUARD_BYTE)
	slice.fill(ref_y_buf, GUARD_BYTE)
	got_cb_buf, got_cb := make_guarded(i420_chroma_size)
	defer delete(got_cb_buf)
	ref_cb_buf, ref_cb := make_guarded(i420_chroma_size)
	defer delete(ref_cb_buf)
	got_cr_buf, got_cr := make_guarded(i420_chroma_size)
	defer delete(got_cr_buf)
	ref_cr_buf, ref_cr := make_guarded(i420_chroma_size)
	defer delete(ref_cr_buf)

	h264.to_i420(frame, got_y, luma_stride, got_cb, got_cr, i420_chroma_stride)
	ref_to_i420(frame, ref_y, luma_stride, ref_cb, ref_cr, i420_chroma_stride)

	expect_guards_intact(t, got_y_buf, "i420 luma", loc)
	expect_guards_intact(t, got_cb_buf, "i420 cb", loc)
	expect_guards_intact(t, got_cr_buf, "i420 cr", loc)
	if !slice.equal(got_y, ref_y) {
		for i in 0 ..< len(got_y) {
			if got_y[i] != ref_y[i] {
				testing.expectf(t, false, "%s I420 luma mismatch at byte %d: got %d want %d", label, i, got_y[i], ref_y[i], loc = loc)
				break
			}
		}
	}
	if !slice.equal(got_cb, ref_cb) {
		for i in 0 ..< len(got_cb) {
			if got_cb[i] != ref_cb[i] {
				testing.expectf(t, false, "%s I420 cb mismatch at byte %d: got %d want %d", label, i, got_cb[i], ref_cb[i], loc = loc)
				break
			}
		}
	}
	if !slice.equal(got_cr, ref_cr) {
		for i in 0 ..< len(got_cr) {
			if got_cr[i] != ref_cr[i] {
				testing.expectf(t, false, "%s I420 cr mismatch at byte %d: got %d want %d", label, i, got_cr[i], ref_cr[i], loc = loc)
				break
			}
		}
	}
}

@(test)
convert_simd_matches_scalar_sizes_and_strides :: proc(t: ^testing.T) {
	Size :: struct { w, h: int }
	sizes := []Size{
		{1, 1}, {1, 2}, {2, 1}, {2, 2}, {3, 3}, {4, 4},
		{7, 1}, {7, 2}, {7, 3},
		{8, 1}, {8, 2}, {8, 3},
		{9, 1}, {9, 2}, {9, 3},
		{15, 2}, {15, 3}, {16, 2}, {16, 3}, {17, 2}, {17, 3},
		{23, 5}, {24, 4}, {25, 5},
		{31, 3}, {32, 4}, {33, 5},
		{63, 7}, {64, 6}, {65, 7},
		{127, 19}, {129, 21},
		{1283, 721},
	}
	Padding :: struct { src, luma, chroma: int }
	paddings := []Padding{
		{0, 0, 0},
		{4, 0, 0},
		{3, 5, 3},   // unaligned odd byte strides
		{28, 17, 13},
	}

	seed: u64 = 0x51A0_2640_BEEF_C0DE
	for sz in sizes {
		for pad, pi in paddings {
			// Skip extra padding rounds on the largest random frame to keep the test fast.
			if sz.w > 200 && pi > 1 { continue }
			stride := sz.w * 4 + pad.src
			// Tight final row: exact frame_fits minimum length (no extra bytes after last pixel).
			pixel_bytes := stride * (sz.h - 1) + sz.w * 4
			pixels_buf, pixels := make_guarded(pixel_bytes)
			fill_random(pixels, &seed)

			for format in ([?]h264.Pixel_Format{.BGRA, .RGBA}) {
				frame := h264.Frame{pixels = pixels, width = sz.w, height = sz.h, stride = stride, format = format}
				label := fmt.tprintf("%dx%d %v pad=%v", sz.w, sz.h, format, pad)
				check_frame_exact(t, frame, pad.luma, pad.chroma, label)
				expect_guards_intact(t, pixels_buf, "source pixels")
			}
			delete(pixels_buf)
		}
	}
}

@(test)
convert_simd_matches_scalar_extremes :: proc(t: ^testing.T) {
	// Width 35 exercises AVX2 (32), SSE2 (8), and odd-column scalar tail in every case.
	W, H :: 35, 5
	Pattern :: struct { name: string, c0, c1, c2, c3: u8 }
	patterns := []Pattern{
		{"all_zero", 0, 0, 0, 0},
		{"all_255", 255, 255, 255, 255},
		{"pure_ch0", 255, 0, 0, 0},
		{"pure_ch1", 0, 255, 0, 0},
		{"pure_ch2", 0, 0, 255, 0},
		{"pure_alpha", 0, 0, 0, 255},
		{"ch0_ch1_max", 255, 255, 0, 255},
		{"ch1_ch2_max", 0, 255, 255, 255},
		{"ch0_ch2_max", 255, 0, 255, 255},
		{"mid_grey", 128, 128, 128, 128},
		{"low_1", 1, 1, 1, 1},
		{"high_254", 254, 254, 254, 254},
	}

	pixels := make([]u8, W * H * 4)
	defer delete(pixels)

	for pat in patterns {
		for i := 0; i < len(pixels); i += 4 {
			pixels[i] = pat.c0
			pixels[i + 1] = pat.c1
			pixels[i + 2] = pat.c2
			pixels[i + 3] = pat.c3
		}
		for format in ([?]h264.Pixel_Format{.BGRA, .RGBA}) {
			frame := h264.Frame{pixels = pixels, width = W, height = H, stride = W * 4, format = format}
			check_frame_exact(t, frame, 7, 5, fmt.tprintf("extreme %s %v", pat.name, format))
		}
	}

	// Checkerboard of extreme 0 and 255 pixels to stress 2x2 chroma sums (0, 255, 510, 765, 1020) and rounding boundaries.
	for y in 0 ..< H {
		for x in 0 ..< W {
			p := (y * W + x) * 4
			hi := ((x + y) & 1) == 0
			pixels[p] = hi ? 255 : 0
			pixels[p + 1] = (x & 1) == 0 ? 255 : 0
			pixels[p + 2] = (y & 1) == 0 ? 255 : 0
			pixels[p + 3] = hi ? 0 : 255
		}
	}
	for format in ([?]h264.Pixel_Format{.BGRA, .RGBA}) {
		frame := h264.Frame{pixels = pixels, width = W, height = H, stride = W * 4, format = format}
		check_frame_exact(t, frame, 3, 3, fmt.tprintf("checkerboard %v", format))
	}

	// Sweep all 256 byte values in each channel across every SIMD lane position and verify alpha is ignored.
	SW, SH :: 256, 4
	sweep := make([]u8, SW * SH * 4)
	defer delete(sweep)
	for y in 0 ..< SH {
		for x in 0 ..< SW {
			p := (y * SW + x) * 4
			sweep[p] = u8((x + y * 37) & 0xFF)
			sweep[p + 1] = u8((x * 3 + y * 91) & 0xFF)
			sweep[p + 2] = u8((255 - x + y * 53) & 0xFF)
			sweep[p + 3] = u8((x * 7 + y * 13) & 0xFF)
		}
	}
	for format in ([?]h264.Pixel_Format{.BGRA, .RGBA}) {
		frame := h264.Frame{pixels = sweep, width = SW, height = SH, stride = SW * 4, format = format}
		check_frame_exact(t, frame, 11, 7, fmt.tprintf("channel_sweep %v", format))
	}
}

@(private = "file")
Bench_Pool :: struct {
	frame:   h264.Frame,
	luma:    []u8,
	chroma:  []u8,
	workers: int,
	stop:    bool,
	start:   sync.Barrier,
	done:    sync.Barrier,
}

@(private = "file")
bench_worker :: proc(t: ^thread.Thread) {
	pool := (^Bench_Pool)(t.data)
	idx := t.user_index
	for {
		sync.barrier_wait(&pool.start)
		if pool.stop { break }
		run_band(pool, idx)
		sync.barrier_wait(&pool.done)
	}
}

@(private = "file")
run_band :: proc(pool: ^Bench_Pool, idx: int) {
	pairs := pool.frame.height / 2
	p0 := (pairs * idx) / pool.workers
	p1 := (pairs * (idx + 1)) / pool.workers
	if p1 <= p0 { return }
	y0 := p0 * 2
	h := (p1 - p0) * 2
	sub := h264.Frame{
		pixels = pool.frame.pixels[y0 * pool.frame.stride:],
		width  = pool.frame.width,
		height = h,
		stride = pool.frame.stride,
		format = pool.frame.format,
	}
	h264.to_nv12(sub, pool.luma[y0 * pool.frame.width:], pool.frame.width, pool.chroma[p0 * pool.frame.width:], pool.frame.width)
}

@(private = "file")
bench_nv12_threaded :: proc(frame: h264.Frame, luma, chroma: []u8, n_threads, warmup, runs: int) -> (min_ms, median_ms: f64) {
	pool: Bench_Pool
	pool.frame = frame
	pool.luma = luma
	pool.chroma = chroma
	pool.workers = n_threads
	sync.barrier_init(&pool.start, n_threads)
	sync.barrier_init(&pool.done, n_threads)

	threads := make([]^thread.Thread, n_threads - 1)
	defer delete(threads)
	for i in 0 ..< n_threads - 1 {
		th := thread.create(bench_worker)
		th.data = &pool
		th.user_index = i + 1
		thread.start(th)
		threads[i] = th
	}
	defer {
		pool.stop = true
		sync.barrier_wait(&pool.start)
		for th in threads {
			thread.join(th)
			thread.destroy(th)
		}
	}

	times := make([]f64, runs)
	defer delete(times)

	for _ in 0 ..< warmup {
		sync.barrier_wait(&pool.start)
		run_band(&pool, 0)
		sync.barrier_wait(&pool.done)
	}
	for i in 0 ..< runs {
		t0 := time.tick_now()
		sync.barrier_wait(&pool.start)
		run_band(&pool, 0)
		sync.barrier_wait(&pool.done)
		times[i] = time.duration_milliseconds(time.tick_since(t0))
	}
	slice.sort(times)
	return times[0], times[runs / 2]
}

@(test)
convert_bench :: proc(t: ^testing.T) {
	if !H264_BENCH { return }
	Res :: struct { name: string, w, h: int }
	resolutions := []Res{
		{"2560x1440", 2560, 1440},
		{"3840x2160", 3840, 2160},
	}
	WARMUP :: 5
	RUNS :: 31
	seed: u64 = 0xB34C_1234_5678_9ABC

	for r in resolutions {
		pixels := make([]u8, r.w * r.h * 4)
		fill_random(pixels, &seed)
		luma := make([]u8, r.w * r.h)
		chroma := make([]u8, r.w * (r.h / 2))
		cb := make([]u8, (r.w / 2) * (r.h / 2))
		cr := make([]u8, (r.w / 2) * (r.h / 2))
		frame := h264.Frame{pixels = pixels, width = r.w, height = r.h, stride = r.w * 4, format = .BGRA}

		times_scalar: [RUNS]f64
		times_simd_nv12: [RUNS]f64
		times_simd_i420: [RUNS]f64

		for _ in 0 ..< WARMUP { ref_to_nv12(frame, luma, r.w, chroma, r.w) }
		for i in 0 ..< RUNS {
			t0 := time.tick_now()
			ref_to_nv12(frame, luma, r.w, chroma, r.w)
			times_scalar[i] = time.duration_milliseconds(time.tick_since(t0))
		}

		for _ in 0 ..< WARMUP { h264.to_nv12(frame, luma, r.w, chroma, r.w) }
		for i in 0 ..< RUNS {
			t0 := time.tick_now()
			h264.to_nv12(frame, luma, r.w, chroma, r.w)
			times_simd_nv12[i] = time.duration_milliseconds(time.tick_since(t0))
		}

		for _ in 0 ..< WARMUP { h264.to_i420(frame, luma, r.w, cb, cr, r.w / 2) }
		for i in 0 ..< RUNS {
			t0 := time.tick_now()
			h264.to_i420(frame, luma, r.w, cb, cr, r.w / 2)
			times_simd_i420[i] = time.duration_milliseconds(time.tick_since(t0))
		}

		slice.sort(times_scalar[:])
		slice.sort(times_simd_nv12[:])
		slice.sort(times_simd_i420[:])

		fmt.printfln(
			"BENCH %s | scalar NV12: min=%.3f ms median=%.3f ms | SIMD NV12: min=%.3f ms median=%.3f ms (%.1fx) | SIMD I420: min=%.3f ms median=%.3f ms (%.1fx)",
			r.name,
			times_scalar[0], times_scalar[RUNS / 2],
			times_simd_nv12[0], times_simd_nv12[RUNS / 2], times_scalar[RUNS / 2] / times_simd_nv12[RUNS / 2],
			times_simd_i420[0], times_simd_i420[RUNS / 2], times_scalar[RUNS / 2] / times_simd_i420[RUNS / 2],
		)

		t2_min, t2_med := bench_nv12_threaded(frame, luma, chroma, 2, WARMUP, RUNS)
		t4_min, t4_med := bench_nv12_threaded(frame, luma, chroma, 4, WARMUP, RUNS)
		t8_min, t8_med := bench_nv12_threaded(frame, luma, chroma, 8, WARMUP, RUNS)
		fmt.printfln(
			"BENCH %s THREADS (NV12) | 1T: min=%.3f med=%.3f | 2T: min=%.3f med=%.3f (%.2fx) | 4T: min=%.3f med=%.3f (%.2fx) | 8T: min=%.3f med=%.3f (%.2fx)",
			r.name,
			times_simd_nv12[0], times_simd_nv12[RUNS / 2],
			t2_min, t2_med, times_simd_nv12[RUNS / 2] / t2_med,
			t4_min, t4_med, times_simd_nv12[RUNS / 2] / t4_med,
			t8_min, t8_med, times_simd_nv12[RUNS / 2] / t8_med,
		)

		delete(pixels)
		delete(luma)
		delete(chroma)
		delete(cb)
		delete(cr)
	}
	_ = t
}
