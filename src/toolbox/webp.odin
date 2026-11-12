package tk_toolbox

// WebP, through cwebp (libwebp's encoder): a screenshot weighs some twenty times less than its PNG, its text as sharp. The
// encoder is the system's where a package manager gives it (nix libwebp, Debian webp); on Windows, libwebp's own build,
// fetched once and pinned (webp_encoder_windows.odin).

import "core:fmt"
import "core:os"
import "core:strings"

// With -preset text: the small text of a screenshot stays as sharp as in the PNG.
WEBP_QUALITY :: 90

// `src` (PNG, JPEG, TIFF or WebP) as a WebP at `dst`, `width` pixels wide (0: its own width), with `encoder` (webp_encoder).
// Says why when it fails.
webp_encode :: proc(encoder, src, dst: string, width := 0, quality := WEBP_QUALITY) -> bool {
	// (-preset first: cwebp reads it before the options it sets)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, encoder, "-preset", "text", "-q", fmt.tprintf("%d", quality), "-metadata", "none", "-quiet")
	if width > 0 { append(&command, "-resize", fmt.tprintf("%d", width), "0") }
	append(&command, src, "-o", dst)
	state, _, stderr, err := os.process_exec({command = command[:]}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("webp: %s did not start (libwebp's encoder: nix libwebp, Debian webp)", encoder)
		return false
	}
	if !state.exited || state.exit_code != 0 {
		fmt.eprintfln("webp: %s: %s", src, strings.trim_space(string(stderr)))
		return false
	}
	return true
}

// A picture's width, from the header of its PNG or WebP file (pure). Not ok: neither, or too short.
image_width :: proc(data: []u8) -> (width: int, ok: bool) {
	if len(data) >= 24 && string(data[:8]) == "\x89PNG\r\n\x1a\n" {
		return int(data[16]) << 24 | int(data[17]) << 16 | int(data[18]) << 8 | int(data[19]), true
	}
	if len(data) < 30 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WEBP" { return }
	switch string(data[12:16]) {
	case "VP8 ":   // lossy: after the frame tag and the start code, 14 bits of width
		return (int(data[26]) | int(data[27]) << 8) & 0x3fff, true
	case "VP8L":   // lossless: after the signature byte, 14 bits of width less one
		return (int(data[21]) | int(data[22]) << 8) & 0x3fff + 1, true
	case "VP8X":   // extended: 24 bits of the canvas's width less one
		return (int(data[24]) | int(data[25]) << 8 | int(data[26]) << 16) + 1, true
	}
	return
}
