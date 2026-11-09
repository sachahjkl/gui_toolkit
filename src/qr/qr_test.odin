// The matrices of Project Nayuki's reference encoder (qrcodegen 1.8, Python, encode_segments with boostecl=False) for a
// few texts, every mode and level; CRC-32s of larger ones (versions 11, 32, 40); the version chosen at each version's
// capacity and one byte, digit or character over it, for every mode and level.
//   odin test src/qr -vet
package qr

import "core:hash"
import "core:strings"
import "core:testing"

// The code as rows of '#' (dark) and '.' (light), each after a newline: the reference's matrices below.
@(private = "file")
picture :: proc(code: Code, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for y in 0 ..< code.size {
		strings.write_byte(&b, '\n')
		for x in 0 ..< code.size { strings.write_byte(&b, module(code, x, y) ? '#' : '.') }
	}
	return strings.to_string(b)
}

@(private = "file")
expect_matrix :: proc(t: ^testing.T, text: string, ecc: Ecc, version, mask: int, want: string) {
	code, err := encode(text, ecc)
	defer destroy(&code)
	testing.expectf(t, err == .None, "%q: %v", text, err)
	testing.expectf(t, code.version == version && code.mask == mask && code.size == version * 4 + 17,
		"%q: version %d mask %d size %d, want version %d mask %d", text, code.version, code.mask, code.size, version, mask)
	testing.expectf(t, picture(code) == want, "%q at %v: the matrix differs from the reference's%s", text, ecc, picture(code))
}

@(test)
matrices_of_the_reference :: proc(t: ^testing.T) {
	expect_matrix(t, "HELLO WORLD", .Quartile, 1, 0, HELLO_WORLD_Q)   // alphanumeric
	expect_matrix(t, "01234567", .Medium, 1, 0, DIGITS_M)              // numeric
	expect_matrix(t, "héllo wörld", .High, 2, 2, UTF8_H)               // bytes, UTF-8
	expect_matrix(t, "", .Low, 1, 7, EMPTY_L)                          // no segment: only padding
	expect_matrix(t, URL, .Medium, 6, 2, URL_M)
}

@(private = "file")
URL :: "https://abcdef0123456789.cfmfdgcrti5w.opentunnel.xyz/auth/connect/0123456789abcdef0123456789abcdef"

@(private = "file")
letters :: proc(n: int) -> string {
	b := make([]u8, n, context.temp_allocator)
	for &c, i in b { c = 'a' + u8(i * 7 % 26) }
	return string(b)
}

@(test)
larger_versions_match_the_reference :: proc(t: ^testing.T) {
	Case :: struct { n: int, ecc: Ecc, version, mask: int, crc: u32 }
	for c in ([]Case{{300, .Low, 11, 2, 0x12fa9e85}, {1500, .Medium, 32, 2, 0x2e9e94b7}, {2953, .Low, 40, 2, 0x82c629a9}}) {
		code, err := encode(letters(c.n), c.ecc)
		defer destroy(&code)
		p := picture(code)
		crc := hash.crc32(transmute([]u8)p[1:])   // (the reference's rows, without the first newline)
		testing.expectf(t, err == .None && code.version == c.version && code.mask == c.mask && crc == c.crc,
			"%d letters at %v: %v, version %d mask %d crc %x", c.n, c.ecc, err, code.version, code.mask, crc)
	}
}

// The most bytes, digits and alphanumeric characters each version holds at each level (the reference's; ISO/IEC 18004
// table 7).
@(private = "file")
CAPACITY := [Ecc][Mode][40]int{
	.Low = {
		.Byte = {17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458, 520, 586, 644, 718, 792, 858, 929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732, 1840, 1952, 2068, 2188, 2303, 2431, 2563, 2699, 2809, 2953},
		.Numeric = {41, 77, 127, 187, 255, 322, 370, 461, 552, 652, 772, 883, 1022, 1101, 1250, 1408, 1548, 1725, 1903, 2061, 2232, 2409, 2620, 2812, 3057, 3283, 3517, 3669, 3909, 4158, 4417, 4686, 4965, 5253, 5529, 5836, 6153, 6479, 6743, 7089},
		.Alphanumeric = {25, 47, 77, 114, 154, 195, 224, 279, 335, 395, 468, 535, 619, 667, 758, 854, 938, 1046, 1153, 1249, 1352, 1460, 1588, 1704, 1853, 1990, 2132, 2223, 2369, 2520, 2677, 2840, 3009, 3183, 3351, 3537, 3729, 3927, 4087, 4296},
	},
	.Medium = {
		.Byte = {14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412, 450, 504, 560, 624, 666, 711, 779, 857, 911, 997, 1059, 1125, 1190, 1264, 1370, 1452, 1538, 1628, 1722, 1809, 1911, 1989, 2099, 2213, 2331},
		.Numeric = {34, 63, 101, 149, 202, 255, 293, 365, 432, 513, 604, 691, 796, 871, 991, 1082, 1212, 1346, 1500, 1600, 1708, 1872, 2059, 2188, 2395, 2544, 2701, 2857, 3035, 3289, 3486, 3693, 3909, 4134, 4343, 4588, 4775, 5039, 5313, 5596},
		.Alphanumeric = {20, 38, 61, 90, 122, 154, 178, 221, 262, 311, 366, 419, 483, 528, 600, 656, 734, 816, 909, 970, 1035, 1134, 1248, 1326, 1451, 1542, 1637, 1732, 1839, 1994, 2113, 2238, 2369, 2506, 2632, 2780, 2894, 3054, 3220, 3391},
	},
	.Quartile = {
		.Byte = {11, 20, 32, 46, 60, 74, 86, 108, 130, 151, 177, 203, 241, 258, 292, 322, 364, 394, 442, 482, 509, 565, 611, 661, 715, 751, 805, 868, 908, 982, 1030, 1112, 1168, 1228, 1283, 1351, 1423, 1499, 1579, 1663},
		.Numeric = {27, 48, 77, 111, 144, 178, 207, 259, 312, 364, 427, 489, 580, 621, 703, 775, 876, 948, 1063, 1159, 1224, 1358, 1468, 1588, 1718, 1804, 1933, 2085, 2181, 2358, 2473, 2670, 2805, 2949, 3081, 3244, 3417, 3599, 3791, 3993},
		.Alphanumeric = {16, 29, 47, 67, 87, 108, 125, 157, 189, 221, 259, 296, 352, 376, 426, 470, 531, 574, 644, 702, 742, 823, 890, 963, 1041, 1094, 1172, 1263, 1322, 1429, 1499, 1618, 1700, 1787, 1867, 1966, 2071, 2181, 2298, 2420},
	},
	.High = {
		.Byte = {7, 14, 24, 34, 44, 58, 64, 84, 98, 119, 137, 155, 177, 194, 220, 250, 280, 310, 338, 382, 403, 439, 461, 511, 535, 593, 625, 658, 698, 742, 790, 842, 898, 958, 983, 1051, 1093, 1139, 1219, 1273},
		.Numeric = {17, 34, 58, 82, 106, 139, 154, 202, 235, 288, 331, 374, 427, 468, 530, 602, 674, 746, 813, 919, 969, 1056, 1108, 1228, 1286, 1425, 1501, 1581, 1677, 1782, 1897, 2022, 2157, 2301, 2361, 2524, 2625, 2735, 2927, 3057},
		.Alphanumeric = {10, 20, 35, 50, 64, 84, 93, 122, 143, 174, 200, 227, 259, 283, 321, 365, 408, 452, 493, 557, 587, 640, 672, 744, 779, 864, 910, 958, 1016, 1080, 1150, 1226, 1307, 1394, 1431, 1530, 1591, 1658, 1774, 1852},
	},
}

// The version chosen from the length alone (the masks are not needed): what encode picks, without drawing 960 symbols.
@(private = "file")
version_for :: proc(n: int, mode: Mode, ecc: Ecc) -> int {
	for v in MIN_VERSION ..= MAX_VERSION {
		if used := segment_bits(mode, n, v); used >= 0 && used <= data_codewords(v, ecc) * 8 { return v }
	}
	return 0
}

@(test)
smallest_version_at_each_boundary :: proc(t: ^testing.T) {
	for ecc in Ecc {
		for mode in Mode {
			for v in 1 ..= 40 {
				n := CAPACITY[ecc][mode][v - 1]
				testing.expectf(t, version_for(n, mode, ecc) == v, "%d %v at %v: version %d, want %d", n, mode, ecc, version_for(n, mode, ecc), v)
				over := v < 40 ? v + 1 : 0
				testing.expectf(t, version_for(n + 1, mode, ecc) == over, "%d %v at %v: version %d, want %d", n + 1, mode, ecc, version_for(n + 1, mode, ecc), over)
			}
		}
	}
	// and through encode, with the text's own mode, either side of a few boundaries
	Case :: struct { text: string, ecc: Ecc, version: int }
	cases := []Case{
		{strings.repeat("a", 17, context.temp_allocator), .Low, 1}, {strings.repeat("a", 18, context.temp_allocator), .Low, 2},
		{strings.repeat("7", 34, context.temp_allocator), .Medium, 1}, {strings.repeat("7", 35, context.temp_allocator), .Medium, 2},
		{strings.repeat("A", 1852, context.temp_allocator), .High, 40},
		{strings.repeat("a", 2331, context.temp_allocator), .Medium, 40},
		{URL, .Low, 5}, {URL, .High, 9},
	}
	for c in cases {
		code, err := encode(c.text, c.ecc)
		defer destroy(&code)
		testing.expectf(t, err == .None && code.version == c.version, "%d chars at %v: %v version %d, want %d", len(c.text), c.ecc, err, code.version, c.version)
	}
}

@(test)
too_long_is_an_error :: proc(t: ^testing.T) {
	code, err := encode(strings.repeat("a", 2954, context.temp_allocator), .Low)
	testing.expect(t, err == .Too_Long && code.modules == nil, "2954 bytes do not fit version 40-L")
	code2, err2 := encode(strings.repeat("7", 5597, context.temp_allocator), .Medium)
	testing.expect(t, err2 == .Too_Long && code2.modules == nil, "5597 digits do not fit version 40-M")
	digits, err3 := encode(strings.repeat("7", 7089, context.temp_allocator), .Low)
	defer destroy(&digits)
	testing.expect(t, err3 == .None && digits.version == 40, "7089 digits fit version 40-L")
}

@(test)
bytes_mode_and_module_outside :: proc(t: ^testing.T) {
	// "01234567" as bytes is not the numeric code; module is light outside the symbol (the quiet zone)
	data := "01234567"
	code, err := encode_bytes(transmute([]u8)data)
	defer destroy(&code)
	testing.expect(t, err == .None && code.version == 1 && picture(code) != DIGITS_M, "bytes mode")
	testing.expect(t, module(code, 0, 0) && !module(code, -1, 0) && !module(code, 0, code.size) && !module(code, code.size, 3), "outside")
}

// HELLO_WORLD_Q: 'HELLO WORLD' Q version 1 mask 0
@(private = "file") HELLO_WORLD_Q :: `
#######.##....#######
#.....#.#..#..#.....#
#.###.#.#..##.#.###.#
#.###.#.#.....#.###.#
#.###.#.#.#...#.###.#
#.....#...#...#.....#
#######.#.#.#.#######
........#............
.##.#.##....#.#.#####
.#......####....#...#
..##.###.##...#.##...
.##.##.#..##.#.#.###.
#...#.#.#.###.###.#.#
........##.#..#...#.#
#######.#.#....#.##..
#.....#..#.##.##.#...
#.###.#.#.#...#######
#.###.#..#.#.#.#...#.
#.###.#.#..#.###.#..#
#.....#.#.####...#.##
#######....#.###....#`

// DIGITS_M: '01234567' M version 1 mask 0
@(private = "file") DIGITS_M :: `
#######...###.#######
#.....#.###...#.....#
#.###.#..##...#.###.#
#.###.#..#.##.#.###.#
#.###.#.##.##.#.###.#
#.....#....#..#.....#
#######.#.#.#.#######
.....................
#.#.#.#...#.#...#..#.
##.#....#.##.#.#...#.
...##.###.##.###.###.
##..##.#.#.###.##..#.
..#..###.###.###....#
........#.#...#....#.
#######.....#...#...#
#.....#...#...#..#.##
#.###.#.###.#.#.###.#
#.###.#..#.#.#.#.###.
#.###.#.##.#.###..#.#
#.....#....###.###...
#######.#..#.###..#.#`

// UTF8_H: 'héllo wörld' H version 2 mask 2
@(private = "file") UTF8_H :: `
#######.#..#####..#######
#.....#.#..###.##.#.....#
#.###.#.###...##..#.###.#
#.###.#....###....#.###.#
#.###.#....###..#.#.###.#
#.....#.#.#######.#.....#
#######.#.#.#.#.#.#######
........#....#.##........
..###.#.#...#..#.###..###
#.###..###.#...#.#..###..
##...#####..###..####....
#.####.#........#......#.
..#...#.#...##.#.##..##.#
####.#.####.#.####.##.#.#
#..#.##.#....#....####.#.
#...##.####.##..#..#....#
#.##.##.#.##..#.#######..
........#....####...#.#..
#######..#....###.#.##.##
#.....#...#...###...#..##
#.###.#.##.#...#########.
#.###.#.#.#..#.#.####.#.#
#.###.#.#.#.#......#..#.#
#.....#..#.##..###...#..#
#######....#.#....#..####`

// EMPTY_L: '' L version 1 mask 7
@(private = "file") EMPTY_L :: `
#######..#.##.#######
#.....#.##.#..#.....#
#.###.#.##..#.#.###.#
#.###.#..#.#..#.###.#
#.###.#.#...#.#.###.#
#.....#.#..##.#.....#
#######.#.#.#.#######
........#####........
##.#..##.##...###.##.
.####..#.#....#...#..
#######.##..##.....##
..##...##.##.....##.#
......#.##..#.#.#.#.#
........#..#...###...
#######.#.#..#.#..###
#.....#..#.###.###.##
#.###.#...##..#####..
#.###.#.####.....####
#.###.#..##.#...#...#
#.....#.#.#..##.#.#..
#######.#####...###..`

// URL_M: 'https://abcdef0123456789.cfmfdgcrti5w.opentunnel.xyz/auth/connect/0123456789abcdef0123456789abcdef' M version 6 mask 2
@(private = "file") URL_M :: `
#######...#..#.##.###.###.#...###.#######
#.....#..##.##.##.#.#.#..#.#.#....#.....#
#.###.#.#...##.............#..###.#.###.#
#.###.#.#..#.#....#.###.####.####.#.###.#
#.###.#.##....#.##.###.#....#..#..#.###.#
#.....#.#.........#..##.####..#.#.#.....#
#######.#.#.#.#.#.#.#.#.#.#.#.#.#.#######
........#.###...#....#.#...#.............
#.#####..###....#####..#.#.#.#.#..#####..
.#......#.##.###.###..###.#.#.#######.###
###...##...##..##.#...#...###...##.#.....
###.##...##.##.#.....#.##.###..#####.#...
##..#.###..#.##..#.#..#.####.#.###...##..
.##.#...#.####......##..#...#..#..#####.#
####.##.#.###....###..#.#..##...##.#.#...
.####..#..#.####..####.#..##....#.####...
#.....#.#..#######.#.....#.###...#.#..##.
..#.#...#...#.##.########.#...###.####.##
.#.##.#.....##.###..##..##.###...#..##...
#.##...#..#..######..##...#.#..##.#.##.##
##..###.##.####.#..###..###.####...#.##..
##......#.#.##..########....#..##.#.##.##
......##..##.#...#...##....####..#.##.#..
.#####.......##...#####.....#.#.#.#.#..##
#.#...####.....###.##....#...#.......###.
#...##........##.###.######.#.##.##.##.##
#..##.##.##.#.##.##.###.####.#..##..#....
.#.##....#.#.##...#######..##..##.#..#.#.
#..########.#.#####.#.#.####.#####...##..
#.#..#.#.#####.##.#..#.#..#.#.##..####.##
#..#..#.#..#.#..###.#.#..#.####..##.#.#..
#..#.......#..#......##....#....######..#
#.#..###...##.####..#....#...#..#####.#.#
........##.#.##.#.##..###.#..#..#...##.##
#######...#....##.#...#...##..###.#.#....
#.....#.#####..........##..##.###...##..#
#.###.#.#.#####...##.##..###.##.#####.##.
#.###.#.#..#...##..#.#.#....#..###.#...##
#.###.#.#.#.#..#.##...#.#..#.########....
#.....#..#...######.##....#.#..###..#..#.
#######.####..##.#.##....#...#.#.######..`

