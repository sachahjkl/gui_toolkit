package ui

// Storage-independent frecency model (src/md/features/fuzzy-frecency.md), shared verbatim with modus's
// src/md/features/fuzzy_match.md ("The frecency model"):
// - Key: 64-bit FNV-1a of the name bytes, mapping 0 to 1.
// - Decay: counts uses (not clock time). Each use decays kept scores by ceil(score / 32) = (score + 31) >> 5
//   (evicting 0s), then adds FRECENCY_USE_WEIGHT (1024) to up to 16 distinct non-empty names (clamped to 32767).
// - Capacity: 64 entries sorted by key (binary search in <= 6 steps); full table evicts lowest score outside current use.
// - Bonus: min(bit_length(score >> 7), 8) -> 0..8, strictly below every structural fuzzy_score bonus.

import "base:intrinsics"

FRECENCY_CAPACITY :: 64
FRECENCY_USE_WEIGHT :: 1024
FRECENCY_DECAY_SHIFT :: 5
FRECENCY_SCORE_LIMIT :: FRECENCY_USE_WEIGHT << FRECENCY_DECAY_SHIFT   // 32768
FRECENCY_NAMES_PER_USE :: 16
FRECENCY_BONUS_SHIFT :: 7
FRECENCY_BONUS_LIMIT :: 8

#assert(FRECENCY_BONUS_LIMIT < FUZZY_SCORE_CHAR)
#assert(FRECENCY_BONUS_LIMIT < FUZZY_SCORE_CAMEL_START)
#assert(FRECENCY_BONUS_LIMIT < FUZZY_SCORE_WORD_START)
#assert(FRECENCY_BONUS_LIMIT < FUZZY_SCORE_TEXT_START)
#assert(FRECENCY_BONUS_LIMIT < FUZZY_SCORE_ADJACENT)
#assert((FRECENCY_SCORE_LIMIT - 1) >> FRECENCY_BONUS_SHIFT == 255 && FRECENCY_BONUS_LIMIT == 8)
#assert(FRECENCY_NAMES_PER_USE < FRECENCY_CAPACITY)

// One kept name: its 64-bit FNV-1a hash (never 0) and its decayed score (1..FRECENCY_SCORE_LIMIT-1).
Frecency_Entry :: struct {
	key:   u64,
	score: u32,
}

// Up to FRECENCY_CAPACITY names sorted by key. Zero value is an empty table.
Frecency :: struct {
	entries: [FRECENCY_CAPACITY]Frecency_Entry,
	count:   int,
}

// 64-bit FNV-1a hash of `name`'s bytes, with 0 mapped to 1 so 0 means no key.
frecency_key :: proc "contextless" (name: string) -> u64 {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for i in 0 ..< len(name) {
		hash = (hash ~ u64(name[i])) * 0x0000_0100_0000_01B3
	}
	return hash == 0 ? 1 : hash
}

@(private = "file")
frecency_count :: proc "contextless" (table: ^Frecency) -> int {
	return clamp(table.count, 0, FRECENCY_CAPACITY)
}

@(private = "file")
frecency_find :: proc "contextless" (table: ^Frecency, key: u64) -> (place: int, found: bool) {
	count := frecency_count(table)
	low, high := 0, count
	for low < high {
		mid := (low + high) / 2
		if table.entries[mid].key < key { low = mid + 1 } else { high = mid }
	}
	return low, low < count && table.entries[low].key == key
}

// The current decayed score of `name`, or 0 when `table` is nil or does not hold it.
frecency_score :: proc "contextless" (table: ^Frecency, name: string) -> u32 {
	if table == nil { return 0 }
	place, found := frecency_find(table, frecency_key(name))
	return found ? table.entries[place].score : 0
}

// Ranking bonus for `name`: 0..FRECENCY_BONUS_LIMIT (8). Add only to matched names.
frecency_bonus :: proc "contextless" (table: ^Frecency, name: string) -> int {
	if table == nil || frecency_count(table) == 0 { return 0 }
	scaled := frecency_score(table, name) >> FRECENCY_BONUS_SHIFT
	if scaled == 0 { return 0 }
	return min(32 - int(intrinsics.count_leading_zeros(scaled)), FRECENCY_BONUS_LIMIT)
}

// Counts one use of `names`: decays all kept entries by ceil(score/32) (evicting 0s), then adds FRECENCY_USE_WEIGHT
// to up to FRECENCY_NAMES_PER_USE distinct non-empty names. An empty slice still decays the table.
frecency_note_use :: proc "contextless" (table: ^Frecency, names: []string) {
	if table == nil { return }
	keys: [FRECENCY_NAMES_PER_USE]u64
	key_count := 0
	next_name: for name in names {
		if key_count == FRECENCY_NAMES_PER_USE { break }
		if len(name) == 0 { continue }
		key := frecency_key(name)
		for kept in keys[:key_count] { if kept == key { continue next_name } }
		keys[key_count] = key
		key_count += 1
	}
	count := frecency_count(table)
	kept := 0
	for i in 0 ..< count {
		e := table.entries[i]
		e.score = min(e.score, FRECENCY_SCORE_LIMIT - 1)
		e.score -= (e.score + (1 << FRECENCY_DECAY_SHIFT) - 1) >> FRECENCY_DECAY_SHIFT
		if e.score > 0 && e.key != 0 {
			table.entries[kept] = e
			kept += 1
		}
	}
	table.count = kept
	for key in keys[:key_count] { frecency_add(table, key, keys[:key_count]) }
}

@(private = "file")
frecency_add :: proc "contextless" (table: ^Frecency, key: u64, use: []u64) {
	place, found := frecency_find(table, key)
	if found {
		table.entries[place].score = min(table.entries[place].score + FRECENCY_USE_WEIGHT, FRECENCY_SCORE_LIMIT - 1)
		return
	}
	if table.count == FRECENCY_CAPACITY {
		lowest := -1
		next_entry: for e, i in table.entries[:table.count] {
			for u in use { if u == e.key { continue next_entry } }
			if lowest < 0 || e.score < table.entries[lowest].score { lowest = i }
		}
		if lowest < 0 { return }
		copy(table.entries[lowest:table.count - 1], table.entries[lowest + 1:table.count])
		table.count -= 1
		if lowest < place { place -= 1 }
	}
	copy(table.entries[place + 1:table.count + 1], table.entries[place:table.count])
	table.entries[place] = {key = key, score = FRECENCY_USE_WEIGHT}
	table.count += 1
}

// Binary wire format for storing a Frecency table in any store (LMDB, file): 4-byte magic "FR01", 4-byte count, then
// `count` entries of (u64le key, u32le score) = 8 + 12 * count bytes (at most 776 bytes).
FRECENCY_BYTES_MAX :: 8 + FRECENCY_CAPACITY * 12

@(private = "file") FRECENCY_MAGIC :: [4]u8{'F', 'R', '0', '1'}

// Writes `table` into `buf` (at least FRECENCY_BYTES_MAX bytes) and returns the written slice.
frecency_encode :: proc "contextless" (table: ^Frecency, buf: []u8) -> []u8 {
	if table == nil || len(buf) < 8 { return nil }
	count := frecency_count(table)
	need := 8 + count * 12
	if len(buf) < need { return nil }
	buf[0], buf[1], buf[2], buf[3] = FRECENCY_MAGIC[0], FRECENCY_MAGIC[1], FRECENCY_MAGIC[2], FRECENCY_MAGIC[3]
	put_u32le(buf[4:8], u32(count))
	for i in 0 ..< count {
		off := 8 + i * 12
		e := table.entries[i]
		put_u64le(buf[off:off + 8], e.key)
		put_u32le(buf[off + 8:off + 12], min(e.score, FRECENCY_SCORE_LIMIT - 1))
	}
	return buf[:need]
}

// Reads a stored table from `data`: clamps scores to FRECENCY_SCORE_LIMIT - 1, drops key 0 or score 0, sorts by key
// and keeps the highest score on duplicate keys. Returns an empty table and false on malformed input.
frecency_decode :: proc "contextless" (data: []u8) -> (table: Frecency, ok: bool) {
	if len(data) < 8 { return {}, false }
	if data[0] != FRECENCY_MAGIC[0] || data[1] != FRECENCY_MAGIC[1] || data[2] != FRECENCY_MAGIC[2] || data[3] != FRECENCY_MAGIC[3] {
		return {}, false
	}
	count := int(get_u32le(data[4:8]))
	if count < 0 || count > FRECENCY_CAPACITY || len(data) != 8 + count * 12 { return {}, false }
	for i in 0 ..< count {
		off := 8 + i * 12
		key := get_u64le(data[off:off + 8])
		score := min(get_u32le(data[off + 8:off + 12]), FRECENCY_SCORE_LIMIT - 1)
		if key == 0 || score == 0 { continue }
		place, found := frecency_find(&table, key)
		if found {
			table.entries[place].score = max(table.entries[place].score, score)
			continue
		}
		if table.count < FRECENCY_CAPACITY {
			copy(table.entries[place + 1:table.count + 1], table.entries[place:table.count])
			table.entries[place] = {key = key, score = score}
			table.count += 1
		}
	}
	return table, true
}

@(private = "file")
put_u32le :: proc "contextless" (b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

@(private = "file")
put_u64le :: proc "contextless" (b: []u8, v: u64) {
	put_u32le(b[0:4], u32(v))
	put_u32le(b[4:8], u32(v >> 32))
}

@(private = "file")
get_u32le :: proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24)
}

@(private = "file")
get_u64le :: proc "contextless" (b: []u8) -> u64 {
	return u64(get_u32le(b[0:4])) | (u64(get_u32le(b[4:8])) << 32)
}
