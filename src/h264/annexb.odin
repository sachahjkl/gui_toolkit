package tk_h264

// Annex B: NAL units after start codes (00 00 01, or 00 00 00 01). The encoders give their access units so; this splits
// them, to know what a packet holds (an IDR slice, an SPS) and to give a muxer the units (MP4 stores them with lengths).

// The next NAL unit of `data` from `at` (its header byte first, no start code; trailing zeros dropped), and where to
// look next. ok is false when there is none left.
next_nal :: proc(data: []u8, at: ^int) -> (nal: []u8, ok: bool) {
	start := find_start_code(data, at^)
	if start < 0 { at^ = len(data); return nil, false }
	begin := start + 3
	next := find_start_code(data, begin)
	end := next < 0 ? len(data) : next
	// (a four-byte start code's leading zero, and trailing_zero_8bits, belong to no unit)
	for end > begin && data[end - 1] == 0 { end -= 1 }
	at^ = end
	if next >= 0 { at^ = next }
	return data[begin:end], true
}

// Where the next 00 00 01 at or after `from` starts, -1 if none.
@(private)
find_start_code :: proc(data: []u8, from: int) -> int {
	for i := from; i + 2 < len(data); i += 1 {
		if data[i + 2] > 1 { i += 2; continue }   // (no start code can end in the next two bytes)
		if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 { return i }
	}
	return -1
}

// The nal_unit_type of a unit as next_nal gives it.
nal_type :: proc(nal: []u8) -> u8 { return len(nal) > 0 ? nal[0] & 31 : 0 }

// Whether `data` (Annex B) has a unit of type `unit_type`.
has_nal_type :: proc(data: []u8, unit_type: u8) -> bool {
	at := 0
	for nal in next_nal(data, &at) {
		if nal_type(nal) == unit_type { return true }
	}
	return false
}

// The SPS and the PPS units of `data` (the first of each), nil when absent: what an MP4 muxer puts in its avcC box.
parameter_sets :: proc(data: []u8) -> (sps, pps: []u8) {
	at := 0
	for nal in next_nal(data, &at) {
		switch nal_type(nal) {
		case NAL_SPS: if sps == nil { sps = nal }
		case NAL_PPS: if pps == nil { pps = nal }
		}
	}
	return
}
