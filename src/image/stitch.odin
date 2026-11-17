package tk_image

// One tall picture of a page that scrolls, from screens of it taken one after the other (a scrolling capture). The rows
// that do not move between frames (a sticky header, a status bar) are kept once; the middle of each frame is joined to
// the one before where their rows match. Pure: no capture, no scroll. A caller adds frames on a worker.
// See docs/image.md, "Stitching", and src/md/features/stitch.md.

import "base:builtin"
import "base:runtime"
import "core:hash/xxhash"
import "core:slice"

// Below this many rows, a match between two frames is taken as chance (a blank line, a rule).
STITCH_MIN_OVERLAP :: 16
// The default bound on the picture's height: 240 MiB at 1920 columns.
STITCH_MAX_HEIGHT :: 32768

// A zero field takes its default.
Stitch_Options :: struct {
	min_overlap: int,   // the least overlap, in rows, that joins two frames (STITCH_MIN_OVERLAP)
	max_height:  int,   // the picture's height is never more (STITCH_MAX_HEIGHT)
	// Columns at the right edge left out of the comparison (still in the picture): a window's scroll bar, whose thumb
	// moves with every step, would make no row of one frame equal to a row of the next.
	ignore_right: int,
}

// What a frame did to the picture.
Stitch_Result :: enum {
	Added,        // its new rows were appended (the first frame: all of them)
	Same,         // it shows what the frame before showed: the page did not move, its end
	No_Overlap,   // no overlap of min_overlap rows with the frame before: refused, nothing changed
	Full,         // max_height is reached: its rows past it are cut, and every later frame adds nothing
	Refused,      // its size is not the first frame's, or its pixels do not match its size
}

// A stitch in progress. Its fields belong to the stitch procedures: begin, add frames, end.
Stitcher :: struct {
	min_overlap, max_height: int,
	ignore_right:            int,
	width, height:           int,    // every frame's, from the first
	compared:                int,    // the bytes of a row that are compared (the width less ignore_right)
	header, footer:          int,    // rows that do not move, known once two frames differed (`fixed`)
	fixed:                   bool,
	full:                    bool,
	body:                    [dynamic]u8,   // the picture so far, without the footer
	prev:                    []u64,         // the row hashes of the last frame added
	tail:                    []u8,          // the footer rows of the last frame added
	allocator:               runtime.Allocator,
}

// A new stitch. Its working memory and the picture `stitch_end` gives are in `allocator`.
stitch_begin :: proc(o := Stitch_Options{}, allocator := context.allocator) -> Stitcher {
	return {
		min_overlap = o.min_overlap > 0 ? o.min_overlap : STITCH_MIN_OVERLAP,
		max_height = o.max_height > 0 ? o.max_height : STITCH_MAX_HEIGHT,
		ignore_right = max(o.ignore_right, 0),
		body = make([dynamic]u8, allocator),
		allocator = allocator,
	}
}

// Adds a frame (its pixels are read, not kept). `moved` is the rows it appended. A capture loop scrolls again while the
// answer is `.Added`; `.Same` is the page's end.
stitch_add :: proc(s: ^Stitcher, frame: Image) -> (moved: int, result: Stitch_Result) {
	if !valid(frame) { return 0, .Refused }
	stride := frame.width * 4
	if s.prev == nil {
		s.width, s.height = frame.width, frame.height
		// (at least one column compared: a frame narrower than the columns left out compares its first)
		s.compared = max(frame.width - s.ignore_right, 1) * 4
		s.prev = make([]u64, frame.height, s.allocator)
		row_hashes(frame, s.compared, s.prev)
		rows := min(frame.height, s.max_height)
		append(&s.body, ..frame.pixels[:rows * stride])
		s.full = rows < frame.height
		return rows, s.full ? Stitch_Result.Full : Stitch_Result.Added
	}
	if frame.width != s.width || frame.height != s.height { return 0, .Refused }
	if s.full { return 0, .Full }

	next := make([]u64, s.height, s.allocator)
	row_hashes(frame, s.compared, next)
	header, footer := s.header, s.footer
	if !s.fixed {
		// The first pair that differs decides the rows that do not move; later frames keep them, as the top of the
		// picture is already written from them.
		for header < s.height && next[header] == s.prev[header] { header += 1 }
		if header == s.height {
			delete(next, s.allocator)
			return 0, .Same
		}
		// bounded so the row that differs stays in the middle
		for footer < s.height - header && next[s.height - 1 - footer] == s.prev[s.height - 1 - footer] { footer += 1 }
	}
	m := s.height - header - footer
	a, b := s.prev[header:][:m], next[header:][:m]
	// The body ends where the last frame's middle ends; before the footer is known, the first frame's footer is in it.
	end := len(s.body) / stride - (s.fixed ? 0 : footer)

	if slice.equal(a, b) && body_matches(s, frame, end, header, m) {
		delete(next, s.allocator)
		return 0, .Same
	}
	// The largest overlap wins: the smallest move, and on rows that repeat the alignment that adds no row twice.
	overlap := 0
	for l := m - 1; l >= s.min_overlap; l -= 1 {
		// the hashes first (one word a row), then the bytes once, so a collision never joins wrong rows
		if slice.equal(a[m - l:], b[:l]) && body_matches(s, frame, end, header, l) {
			overlap = l
			break
		}
	}
	if overlap == 0 {
		delete(next, s.allocator)
		return 0, .No_Overlap
	}

	if !s.fixed {
		s.header, s.footer, s.fixed = header, footer, true
		_ = builtin.resize(&s.body, end * stride)   // (the package's own resize scales a picture)
		s.tail = make([]u8, footer * stride, s.allocator)
	}
	count := m - overlap
	// the footer must still fit under the bound
	n := min(count, max(s.max_height - s.footer - end, 0))
	append(&s.body, ..frame.pixels[(header + overlap) * stride:][:n * stride])
	copy(s.tail, frame.pixels[(s.height - s.footer) * stride:][:s.footer * stride])
	delete(s.prev, s.allocator)
	s.prev = next
	if n < count {
		s.full = true
		return n, .Full
	}
	return n, .Added
}

// The picture: the first frame's header, the middles joined, the last frame's footer, in the allocator given to
// `stitch_begin` (`destroy` it with that allocator). Frees the stitch's working memory. ok is false when no frame was
// added.
stitch_end :: proc(s: ^Stitcher) -> (out: Image, ok: bool) {
	defer s^ = {}
	delete(s.prev, s.allocator)
	if s.width == 0 {
		delete(s.body)
		delete(s.tail, s.allocator)
		return {}, false
	}
	append(&s.body, ..s.tail)
	delete(s.tail, s.allocator)
	// the picture's pixels must be one allocation of their own size, so `destroy` frees them as any picture's
	shrink(&s.body)
	return {pixels = s.body[:], width = s.width, height = len(s.body) / (s.width * 4)}, true
}

// The frames, already taken, stitched in order. It stops at the first frame that adds nothing (`.Same`) or at
// `max_height` (`.Full`): `used` is the frames that gave rows. A frame that does not join (`.No_Overlap`, `.Refused`)
// gives an empty picture and ok = false: a picture with a hole is no answer.
stitch :: proc(frames: []Image, o := Stitch_Options{}, allocator := context.allocator) -> (out: Image, used: int, ok: bool) {
	s := stitch_begin(o, allocator)
	loop: for frame in frames {
		moved, result := stitch_add(&s, frame)
		if moved > 0 { used += 1 }
		switch result {
		case .Added:
		case .Same, .Full:
			break loop
		case .No_Overlap, .Refused:
			img, _ := stitch_end(&s)
			destroy(&img, allocator)
			return {}, used, false
		}
	}
	out, ok = stitch_end(&s)
	return
}

@(private = "file")
row_hashes :: proc(img: Image, compared: int, out: []u64) {
	stride := img.width * 4
	for y in 0 ..< img.height { out[y] = xxhash.XXH3_64_default(img.pixels[y * stride:][:compared]) }
}

// Whether the `l` rows of `frame` from `first` are the body's `l` rows that end at row `end` (their compared bytes).
@(private = "file")
body_matches :: proc(s: ^Stitcher, frame: Image, end, first, l: int) -> bool {
	stride := frame.width * 4
	if l > end { return false }
	for i in 0 ..< l {
		a := s.body[(end - l + i) * stride:][:s.compared]
		b := frame.pixels[(first + i) * stride:][:s.compared]
		if !slice.equal(a, b) { return false }
	}
	return true
}
