// Package exif: the metadata a camera writes in a picture (EXIF: a TIFF structure of tagged values), read from a JPEG's
// APP1 segment, a PNG's eXIf chunk or a WebP's EXIF chunk; the small JPEG a camera puts beside it (its embedded
// thumbnail); and the one value a program writes back, a JPEG's orientation (a turn without touching a pixel). Pure
// Odin, no platform code, no allocation but the strings of read. Every read is bounded by the block's bytes: a damaged or
// crafted file reads as none (docs/exif.md, src/md/features/exif.md).
package exif

import "core:fmt"
import "core:strings"

// What a program shows of a picture's metadata. A field the file does not have is its zero value.
Info :: struct {
	found:         bool,      // the file has a block of metadata
	orientation:   int,       // 1 to 8 (TIFF's), 0: none said (as 1)
	make, model:   string,    // the camera
	lens:          string,
	software:      string,
	taken:         string,    // "YYYY:MM:DD HH:MM:SS", as written (DateTimeOriginal, else DateTime)
	artist:        string,
	copyright:     string,
	description:   string,
	exposure:      [2]u32,    // seconds, a fraction (1/250 is {1, 250}); {0, 0}: none
	f_number:      f64,
	iso:           int,
	focal:         f64,       // millimetres
	focal_35:      int,       // millimetres, as on a 35 mm film
	bias:          f64,       // exposure compensation, in stops
	flash:         int,       // -1: none said; else bit 0 says whether it fired
	pixels:        [2]int,    // the size the camera says (PixelXDimension, PixelYDimension)
	gps:           bool,
	latitude:      f64,       // degrees, south negative
	longitude:     f64,       // degrees, west negative
	altitude:      f64,       // metres
}

// The tags read.
@(private = "file") TAG_DESCRIPTION :: 0x010E
@(private = "file") TAG_MAKE        :: 0x010F
@(private = "file") TAG_MODEL       :: 0x0110
@(private = "file") TAG_ORIENTATION :: 0x0112
@(private = "file") TAG_SOFTWARE    :: 0x0131
@(private = "file") TAG_DATE        :: 0x0132
@(private = "file") TAG_ARTIST      :: 0x013B
@(private = "file") TAG_COPYRIGHT   :: 0x8298
@(private = "file") TAG_EXIF_IFD    :: 0x8769
@(private = "file") TAG_GPS_IFD     :: 0x8825
@(private = "file") TAG_EXPOSURE    :: 0x829A
@(private = "file") TAG_F_NUMBER    :: 0x829D
@(private = "file") TAG_ISO         :: 0x8827
@(private = "file") TAG_TAKEN       :: 0x9003
@(private = "file") TAG_BIAS        :: 0x9204
@(private = "file") TAG_FLASH       :: 0x9209
@(private = "file") TAG_FOCAL       :: 0x920A
@(private = "file") TAG_PIXEL_X     :: 0xA002
@(private = "file") TAG_PIXEL_Y     :: 0xA003
@(private = "file") TAG_FOCAL_35    :: 0xA405
@(private = "file") TAG_LENS        :: 0xA434
@(private = "file") TAG_THUMB_AT    :: 0x0201   // (IFD1: JPEGInterchangeFormat, the embedded JPEG's offset)
@(private = "file") TAG_THUMB_BYTES :: 0x0202   // (IFD1: JPEGInterchangeFormatLength)

// TIFF's value types: their sizes in bytes.
@(private = "file") TYPE_SIZES := [13]int{0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8}
@(private = "file") TYPE_ASCII     :: 2
@(private = "file") TYPE_SHORT     :: 3
@(private = "file") TYPE_LONG      :: 4
@(private = "file") TYPE_RATIONAL  :: 5
@(private = "file") TYPE_SRATIONAL :: 10

// A JPEG segment's marker byte, after 0xFF.
@(private = "file") JPEG_SOI  :: 0xD8
@(private = "file") JPEG_SOS  :: 0xDA
@(private = "file") JPEG_APP0 :: 0xE0
@(private = "file") JPEG_APP1 :: 0xE1
EXIF_HEADER :: "Exif\x00\x00"

// The most IFD entries read in one directory: a damaged count does not read the whole file as tags.
@(private = "file") ENTRIES_MAX :: 1000

// The metadata of a JPEG, PNG or WebP file (by its first bytes). Its strings are in `allocator`: destroy.
read :: proc(data: []u8, allocator := context.allocator) -> (info: Info) {
	tiff := tiff_of(data)
	if tiff == nil { return }
	return read_tiff(tiff, allocator)
}

destroy :: proc(info: ^Info, allocator := context.allocator) {
	for s in ([]string{info.make, info.model, info.lens, info.software, info.taken, info.artist, info.copyright, info.description}) {
		delete(s, allocator)
	}
	info^ = {}
}

// The TIFF block of a file: a JPEG's APP1 "Exif", a PNG's eXIf chunk, a WebP's EXIF chunk. nil: none.
tiff_of :: proc(data: []u8) -> []u8 {
	switch {
	case len(data) > 4 && data[0] == 0xFF && data[1] == JPEG_SOI:
		at, size, _ := jpeg_exif(data)
		if at < 0 { return nil }
		return data[at:][:size]
	case len(data) > 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n":
		for at := 8; at + 12 <= len(data); {
			n := int(be32(data[at:]))
			kind := string(data[at + 4:][:4])
			if at + 12 + n > len(data) { return nil }
			if kind == "eXIf" { return data[at + 8:][:n] }
			if kind == "IDAT" || kind == "IEND" { return nil }   // (eXIf comes before the pixels)
			at += 12 + n
		}
	case len(data) > 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		for at := 12; at + 8 <= len(data); {
			n := int(le32(data[at + 4:]))
			if at + 8 + n > len(data) { return nil }
			if string(data[at:][:4]) == "EXIF" {
				block := data[at + 8:][:n]
				// (some writers keep the JPEG's "Exif\0\0" before the TIFF header)
				if len(block) > 6 && string(block[:6]) == EXIF_HEADER { block = block[6:] }
				return block
			}
			at += 8 + n + (n & 1)
		}
	}
	return nil
}

// Where a JPEG's TIFF block starts and its size (after "Exif\0\0"); -1: none. Only the segments before the scan.
// `clean`: the segments were walked to the scan with no surprise, so that "none" is sure (a block inserted then is the
// only one; a walk that stopped early may have missed one, and two blocks would disagree).
@(private = "file")
jpeg_exif :: proc(data: []u8) -> (at, size: int, clean: bool) {
	for p := 2; p + 4 <= len(data); {
		if data[p] != 0xFF { return -1, 0, false }
		marker := data[p + 1]
		// (fill bytes: any number of 0xFF may come before a marker)
		if marker == 0xFF { p += 1; continue }
		if marker == JPEG_SOS { return -1, 0, true }
		n := int(be16(data[p + 2:]))
		if n < 2 || p + 2 + n > len(data) { return -1, 0, false }
		body := data[p + 4:][:n - 2]
		if marker == JPEG_APP1 && len(body) > 6 && string(body[:6]) == EXIF_HEADER { return p + 4 + 6, n - 2 - 6, true }
		p += 2 + n
	}
	return -1, 0, false
}

@(private = "file")
Tiff :: struct {
	data: []u8,
	big:  bool,
}

@(private = "file") u16_at :: proc(t: Tiff, at: int) -> int {
	if at < 0 || at + 2 > len(t.data) { return 0 }
	return int(t.big ? be16(t.data[at:]) : le16(t.data[at:]))
}
@(private = "file") u32_at :: proc(t: Tiff, at: int) -> u32 {
	if at < 0 || at + 4 > len(t.data) { return 0 }
	return t.big ? be32(t.data[at:]) : le32(t.data[at:])
}

// The metadata of a TIFF block (the bytes after "Exif\0\0").
read_tiff :: proc(data: []u8, allocator := context.allocator) -> (info: Info) {
	if len(data) < 8 { return }
	t := Tiff{data = data}
	switch string(data[:2]) {
	case "MM": t.big = true
	case "II":
	case: return
	}
	if u16_at(t, 2) != 42 { return }
	info.found = true
	info.flash = -1
	exif_ifd, gps_ifd := -1, -1
	ifd(t, int(u32_at(t, 4)), &info, &exif_ifd, &gps_ifd, allocator)
	if exif_ifd > 0 { ifd(t, exif_ifd, &info, nil, nil, allocator) }
	if gps_ifd > 0 { gps(t, gps_ifd, &info) }
	return
}

// Where an entry's value is: inside the entry when it fits in 4 bytes, else at the offset the entry holds.
@(private = "file")
value_at :: proc(t: Tiff, entry: int) -> (at, type, count: int) {
	type = u16_at(t, entry + 2)
	count = int(u32_at(t, entry + 4))
	if type <= 0 || type >= len(TYPE_SIZES) || count < 0 || count > len(t.data) { return -1, type, 0 }
	at = entry + 8
	if TYPE_SIZES[type] * count > 4 { at = int(u32_at(t, entry + 8)) }
	if at + TYPE_SIZES[type] * count > len(t.data) { return -1, type, 0 }
	return
}

@(private = "file")
ifd :: proc(t: Tiff, start: int, info: ^Info, exif_ifd, gps_ifd: ^int, allocator := context.allocator) {
	n := u16_at(t, start)
	if n <= 0 || n > ENTRIES_MAX { return }
	for i in 0 ..< n {
		e := start + 2 + i * 12
		if e + 12 > len(t.data) { return }
		tag := u16_at(t, e)
		at, type, count := value_at(t, e)
		if at < 0 { continue }
		switch tag {
		// (a tag written twice, by a damaged or a crafted file: the last one, the first one's string freed)
		case TAG_ORIENTATION: info.orientation = clamp(number(t, at, type), 0, 8)
		case TAG_MAKE:        text_set(&info.make, t, at, count, allocator)
		case TAG_MODEL:       text_set(&info.model, t, at, count, allocator)
		case TAG_SOFTWARE:    text_set(&info.software, t, at, count, allocator)
		case TAG_DATE:        if info.taken == "" { text_set(&info.taken, t, at, count, allocator) }
		case TAG_TAKEN:       text_set(&info.taken, t, at, count, allocator)
		case TAG_ARTIST:      text_set(&info.artist, t, at, count, allocator)
		case TAG_COPYRIGHT:   text_set(&info.copyright, t, at, count, allocator)
		case TAG_DESCRIPTION: text_set(&info.description, t, at, count, allocator)
		case TAG_LENS:        text_set(&info.lens, t, at, count, allocator)
		case TAG_EXIF_IFD:    if exif_ifd != nil { exif_ifd^ = number(t, at, type) }
		case TAG_GPS_IFD:     if gps_ifd != nil { gps_ifd^ = number(t, at, type) }
		case TAG_EXPOSURE:    if type == TYPE_RATIONAL { info.exposure = {u32_at(t, at), u32_at(t, at + 4)} }
		case TAG_F_NUMBER:    info.f_number = rational(t, at, type)
		case TAG_ISO:         info.iso = number(t, at, type)
		case TAG_FOCAL:       info.focal = rational(t, at, type)
		case TAG_FOCAL_35:    info.focal_35 = number(t, at, type)
		case TAG_BIAS:        info.bias = rational(t, at, type)
		case TAG_FLASH:       info.flash = number(t, at, type)
		case TAG_PIXEL_X:     info.pixels.x = number(t, at, type)
		case TAG_PIXEL_Y:     info.pixels.y = number(t, at, type)
		}
	}
}

@(private = "file")
gps :: proc(t: Tiff, start: int, info: ^Info) {
	n := u16_at(t, start)
	if n <= 0 || n > ENTRIES_MAX { return }
	lat_ref, lon_ref, alt_ref := u8('N'), u8('E'), 0
	lat, lon: f64
	has_lat, has_lon := false, false
	for i in 0 ..< n {
		e := start + 2 + i * 12
		if e + 12 > len(t.data) { break }
		at, type, count := value_at(t, e)
		if at < 0 { continue }
		switch u16_at(t, e) {
		case 1: if count > 0 { lat_ref = t.data[at] }
		case 2: lat, has_lat = degrees(t, at, type, count)
		case 3: if count > 0 { lon_ref = t.data[at] }
		case 4: lon, has_lon = degrees(t, at, type, count)
		case 5: if count > 0 { alt_ref = int(t.data[at]) }
		case 6: info.altitude = rational(t, at, type)
		}
	}
	if !has_lat || !has_lon { return }
	info.gps = true
	info.latitude = lat_ref == 'S' ? -lat : lat
	info.longitude = lon_ref == 'W' ? -lon : lon
	if alt_ref == 1 { info.altitude = -info.altitude }
}

// Degrees, minutes and seconds as three rationals.
@(private = "file")
degrees :: proc(t: Tiff, at, type, count: int) -> (f64, bool) {
	if type != TYPE_RATIONAL || count < 3 { return 0, false }
	d := rational(t, at, type)
	m := rational(t, at + 8, type)
	s := rational(t, at + 16, type)
	return d + m / 60 + s / 3600, true
}

@(private = "file")
number :: proc(t: Tiff, at, type: int) -> int {
	switch type {
	case 1, 7: return int(t.data[at])
	case TYPE_SHORT: return u16_at(t, at)
	case TYPE_LONG:  return int(u32_at(t, at))
	}
	return 0
}

@(private = "file")
rational :: proc(t: Tiff, at, type: int) -> f64 {
	switch type {
	case TYPE_RATIONAL:
		d := u32_at(t, at + 4)
		return d == 0 ? 0 : f64(u32_at(t, at)) / f64(d)
	case TYPE_SRATIONAL:
		d := i32(u32_at(t, at + 4))
		return d == 0 ? 0 : f64(i32(u32_at(t, at))) / f64(d)
	case TYPE_SHORT, TYPE_LONG:
		return f64(number(t, at, type))
	}
	return 0
}

// An ASCII value, its trailing zeros and spaces cut.
@(private = "file")
text :: proc(t: Tiff, at, count: int, allocator := context.allocator) -> string {
	s := string(t.data[at:][:count])
	if i := strings.index_byte(s, 0); i >= 0 { s = s[:i] }
	return strings.clone(strings.trim_space(s), allocator)
}

@(private = "file")
text_set :: proc(field: ^string, t: Tiff, at, count: int, allocator := context.allocator) {
	delete(field^, allocator)
	field^ = text(t, at, count, allocator)
}

// The orientation of a file (1 to 8; 0: none said, as 1), read without allocating: what a decoder asks before it turns
// the pixels.
orientation :: proc(data: []u8) -> int {
	tiff := tiff_of(data)
	if len(tiff) < 8 { return 0 }
	t := Tiff{data = tiff, big = string(tiff[:2]) == "MM"}
	if !t.big && string(tiff[:2]) != "II" { return 0 }
	if u16_at(t, 2) != 42 { return 0 }
	start := int(u32_at(t, 4))
	n := u16_at(t, start)
	if n <= 0 || n > ENTRIES_MAX { return 0 }
	o := 0
	for i in 0 ..< n {
		e := start + 2 + i * 12
		if e + 12 > len(tiff) { break }
		if u16_at(t, e) != TAG_ORIENTATION { continue }
		at, type, _ := value_at(t, e)
		if at >= 0 { o = clamp(number(t, at, type), 0, 8) }
	}
	return o
}

// The JPEG a camera embeds in its metadata (IFD1: often 160 by 120, a few kilobytes), a slice of `data`, nil when there
// is none: shown at once while the picture decodes. It is checked to start as a JPEG and to lie inside the block, not
// decoded. Its orientation is the picture's (the camera turns neither).
thumbnail :: proc(data: []u8) -> []u8 {
	tiff := tiff_of(data)
	if len(tiff) < 8 { return nil }
	t := Tiff{data = tiff, big = string(tiff[:2]) == "MM"}
	if !t.big && string(tiff[:2]) != "II" { return nil }
	if u16_at(t, 2) != 42 { return nil }
	ifd0 := int(u32_at(t, 4))
	n0 := u16_at(t, ifd0)
	if n0 <= 0 || n0 > ENTRIES_MAX { return nil }
	next := ifd0 + 2 + n0 * 12
	if next + 4 > len(tiff) { return nil }
	ifd1 := int(u32_at(t, next))
	// (IFD1 after IFD0's header: an offset back into it would read IFD0's entries as IFD1's)
	if ifd1 <= 8 || ifd1 == ifd0 { return nil }
	n1 := u16_at(t, ifd1)
	if n1 <= 0 || n1 > ENTRIES_MAX { return nil }
	at, size := -1, 0
	for i in 0 ..< n1 {
		e := ifd1 + 2 + i * 12
		if e + 12 > len(tiff) { break }
		v, type, _ := value_at(t, e)
		if v < 0 { continue }
		switch u16_at(t, e) {
		case TAG_THUMB_AT:    at = number(t, v, type)
		case TAG_THUMB_BYTES: size = number(t, v, type)
		}
	}
	if at <= 0 || size < 4 || at > len(tiff) || size > len(tiff) - at { return nil }
	jpeg := tiff[at:][:size]
	if jpeg[0] != 0xFF || jpeg[1] != JPEG_SOI { return nil }
	return jpeg
}

////////////////////////////////
// Writing the orientation

Write_Result :: enum u8 {
	Changed,    // the value was there: its two bytes changed
	Inserted,   // the file had no metadata: a block with the orientation alone was put after its start
	Refused,    // not a JPEG, or its metadata has no orientation to change (writing one would move every offset)
}

// `data` with the JPEG's orientation set to `o` (1 to 8). The pixels are never touched: the turn is lossless. The
// result is in `allocator` (nil when Refused).
set_orientation :: proc(data: []u8, o: int, allocator := context.allocator) -> (out: []u8, result: Write_Result) {
	if len(data) < 4 || data[0] != 0xFF || data[1] != JPEG_SOI || o < 1 || o > 8 { return nil, .Refused }
	at, size, clean := jpeg_exif(data)
	if at >= 0 {
		value := orientation_offset(data[at:][:size])
		if value < 0 { return nil, .Refused }
		out = make([]u8, len(data), allocator)
		copy(out, data)
		if string(data[at:][:2]) == "MM" {
			out[at + value], out[at + value + 1] = 0, u8(o)
		} else {
			out[at + value], out[at + value + 1] = u8(o), 0
		}
		return out, .Changed
	}
	// (no metadata: a block with one entry, after the JFIF segment when there is one: JFIF must stay first. A header
	// not walked to its end may hide a block: nothing is inserted then)
	if !clean { return nil, .Refused }
	insert := 2
	if len(data) > 6 && data[2] == 0xFF && data[3] == JPEG_APP0 { insert = 4 + int(be16(data[4:])) }
	if insert > len(data) { return nil, .Refused }
	block := orientation_block(o)
	out = make([]u8, len(data) + len(block), allocator)
	copy(out, data[:insert])
	copy(out[insert:], block[:])
	copy(out[insert + len(block):], data[insert:])
	return out, .Inserted
}

// The offset in a TIFF block of the orientation's two bytes; -1: no orientation in IFD0.
orientation_offset :: proc(data: []u8) -> int {
	if len(data) < 8 { return -1 }
	t := Tiff{data = data, big = string(data[:2]) == "MM"}
	if !t.big && string(data[:2]) != "II" { return -1 }
	start := int(u32_at(t, 4))
	n := u16_at(t, start)
	if n <= 0 || n > ENTRIES_MAX { return -1 }
	for i in 0 ..< n {
		e := start + 2 + i * 12
		if e + 12 > len(data) { return -1 }
		// (one SHORT, held inside the entry: with a count past 2 the entry holds an offset, which a write would break)
		if u16_at(t, e) == TAG_ORIENTATION && u16_at(t, e + 2) == TYPE_SHORT && u32_at(t, e + 4) == 1 { return e + 8 }
	}
	return -1
}

// An APP1 segment of one tag, the orientation: "Exif\0\0", a big-endian TIFF header, IFD0 of one entry.
@(private = "file")
ORIENTATION_BLOCK_BYTES :: 2 + 2 + 6 + 8 + 2 + 12 + 4

@(private = "file")
orientation_block :: proc(o: int) -> (b: [ORIENTATION_BLOCK_BYTES]u8) {
	w := 0
	put :: proc(b: []u8, w: ^int, bytes: ..u8) { for x in bytes { b[w^] = x; w^ += 1 } }
	length := ORIENTATION_BLOCK_BYTES - 2
	put(b[:], &w, 0xFF, JPEG_APP1, u8(length >> 8), u8(length))
	put(b[:], &w, 'E', 'x', 'i', 'f', 0, 0)
	put(b[:], &w, 'M', 'M', 0, 42, 0, 0, 0, 8)   // (the IFD right after the header)
	put(b[:], &w, 0, 1)                          // (one entry)
	put(b[:], &w, u8(TAG_ORIENTATION >> 8), u8(TAG_ORIENTATION & 0xFF), 0, TYPE_SHORT, 0, 0, 0, 1, 0, u8(o), 0, 0)
	put(b[:], &w, 0, 0, 0, 0)                    // (no next IFD)
	return
}

////////////////////////////////
// What a person reads

// The exposure as a photographer says it: "1/250 s", "2.5 s"; "": none.
exposure_words :: proc(e: [2]u32, allocator := context.temp_allocator) -> string {
	if e[0] == 0 || e[1] == 0 { return "" }
	if e[0] < e[1] {
		return fmt.aprintf("1/%d s", (e[1] + e[0] / 2) / e[0], allocator = allocator)
	}
	return fmt.aprintf("%.4g s", f64(e[0]) / f64(e[1]), allocator = allocator)
}

// The turns of an orientation: quarters clockwise, and a mirror (TIFF's 1 to 8; 0 is 1).
Turn :: struct {
	quarters: int,    // 0 to 3, clockwise, applied after the mirror
	mirror:   bool,   // left to right
}

orientation_turn :: proc(o: int) -> Turn {
	switch o {
	case 2: return {0, true}
	case 3: return {2, false}
	case 4: return {2, true}
	case 5: return {3, true}   // (the mirror then three quarters: a transpose)
	case 6: return {1, false}
	case 7: return {1, true}   // (the mirror then a quarter: across the other diagonal)
	case 8: return {3, false}
	}
	return {}
}

// The orientation of a turn (orientation_turn's inverse).
turn_orientation :: proc(t: Turn) -> int {
	for o in 1 ..= 8 { if orientation_turn(o) == {((t.quarters % 4) + 4) % 4, t.mirror} { return o } }
	return 1
}

@(private = "file") be16 :: proc(b: []u8) -> u16 { return u16(b[0]) << 8 | u16(b[1]) }
@(private = "file") le16 :: proc(b: []u8) -> u16 { return u16(b[1]) << 8 | u16(b[0]) }
@(private = "file") be32 :: proc(b: []u8) -> u32 { return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3]) }
@(private = "file") le32 :: proc(b: []u8) -> u32 { return u32(b[3]) << 24 | u32(b[2]) << 16 | u32(b[1]) << 8 | u32(b[0]) }
