// The corpus of the text backend comparisons (tools/text_dump, tools/text_bench, tests/text_backends): one sample of
// text per script and feature, with the system font that has it, and a dump of everything the font package says about
// it (glyphs, clusters, widths, bidi levels, line breaks, metrics) as text lines that two runs can diff.
package text_corpus

import "core:fmt"
import "core:strings"
import "../../font"

Sample :: struct {
	name:   string,
	family: string,   // system family ("" : the cascade of Segoe UI with the system fallback)
	text:   string,
	dir:    font.Direction,
}

SAMPLES := [?]Sample{
	{"latin",          "Segoe UI",          "Hello, World! Typography: AV To Wa fi fl ffi 0123456789", .Auto},
	{"latin-liga",     "Gabriola",          "The office affords fine fluffy staffs", .Auto},
	{"latin-kern",     "Times New Roman",   "AVATAR Toward WAVE Yo P. T.", .Auto},
	{"latin-marks",    "Segoe UI",          "e\u0301 a\u0308\u0323 n\u0303 Ǫ̃ ậ", .Auto},
	{"cyrillic-greek", "Segoe UI",          "Привет мир. Καλημέρα κόσμε", .Auto},
	{"arabic",         "Segoe UI",          "مرحبا بالعالم، هذا نص عربي ١٢٣", .Auto},
	{"arabic-mixed",   "Segoe UI",          "abc مرحبا 123 world عالم", .Ltr},
	{"hebrew",         "Segoe UI",          "שלום עולם, זה טקסט בעברית", .Auto},
	{"devanagari",     "Nirmala UI",        "नमस्ते दुनिया क्षत्रिय हिन्दी", .Auto},
	{"thai",           "Leelawadee UI",     "สวัสดีชาวโลกภาษาไทยไม่มีการเว้นวรรค", .Auto},
	{"lao",            "Leelawadee UI",     "ສະບາຍດີຊາວໂລກພາສາລາວ", .Auto},
	{"khmer",          "Leelawadee UI",     "សួស្តីពិភពលោកភាសាខ្មែរ", .Auto},
	{"myanmar",        "Myanmar Text",      "မင်္ဂလာပါကမ္ဘာမြန်မာဘာသာ", .Auto},
	{"cjk-zh",         "Microsoft YaHei",   "你好，世界。中文文本没有空格。", .Auto},
	{"cjk-ja",         "Yu Gothic",         "こんにちは世界。日本語のテキスト、カタカナ。", .Auto},
	{"korean",         "Malgun Gothic",     "안녕하세요 세계 한국어 텍스트", .Auto},
	{"emoji",          "Segoe UI Emoji",    "😀 👍🏽 👨‍👩‍👧‍👦 🇫🇷 ❤️ 1️⃣", .Auto},
	{"variable",       "Bahnschrift",       "Variable font Bahnschrift 0123", .Auto},
	{"fallback",       "",                  "Mix: Привет مرحبا नमस्ते 你好 😀 ←→", .Auto},
}

SIZES :: [?]f32{13, 20}

// Loads the face of a sample (the cascade of Segoe UI with the system fallback for "").
sample_font :: proc(s: ^font.State, sm: Sample) -> (font.Font_Id, bool) {
	family := sm.family != "" ? sm.family : "Segoe UI"
	id, ok := font.load_system(s, family)
	if !ok { return 0, false }
	if sm.family == "" { return font.cascade(s, {{font = id}}), true }
	return id, true
}

// Everything the package says about the corpus, one fact per line.
dump :: proc(s: ^font.State, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for sm in SAMPLES {
		id, ok := sample_font(s, sm)
		if !ok { fmt.sbprintf(&sb, "%s: no font %q\n", sm.name, sm.family); continue }
		dump_sample(&sb, s, sm, id)
	}
	return strings.to_string(sb)
}

dump_sample :: proc(sb: ^strings.Builder, s: ^font.State, sm: Sample, id: font.Font_Id) {
	for size in SIZES {
		m := font.metrics(s, id, size)
		fmt.sbprintf(sb, "%s @%v metrics asc %.3f desc %.3f lh %.3f gap %.3f xh %.3f cap %.3f ul %.3f/%.3f st %.3f/%.3f\n", sm.name, size,
			m.ascent, m.descent, m.line_height, m.line_gap, m.x_height, m.cap_height, m.underline_offset, m.underline_thickness, m.strike_offset, m.strike_thickness)
		sh := font.shape(s, id, size, sm.text, {direction = sm.dir}, context.temp_allocator)
		fmt.sbprintf(sb, "%s @%v width %.3f measure %.3f glyphs %d clusters %d\n", sm.name, size, sh.width,
			font.measure(s, id, size, sm.text, {direction = sm.dir}), len(sh.glyphs), len(sh.clusters))
		for g, i in sh.glyphs {
			fmt.sbprintf(sb, "%s @%v g%d face %d id %d rtl %v x %.3f y %.3f adv %.3f cl %d\n", sm.name, size, i, int(g.face), g.id, g.rtl, g.x, g.y, g.advance, g.cluster)
		}
		for c, i in sh.clusters {
			fmt.sbprintf(sb, "%s @%v c%d [%d,%d) x %.3f..%.3f rtl %v\n", sm.name, size, i, c.start, c.end, c.x0, c.x1, c.rtl)
		}
		sp := font.shape(s, id, size, sm.text, {direction = sm.dir, letter_spacing = 1.5, word_spacing = 2}, context.temp_allocator)
		fmt.sbprintf(sb, "%s @%v spaced width %.3f glyphs %d\n", sm.name, size, sp.width, len(sp.glyphs))
	}
	lv := font.bidi_levels(s, sm.text, sm.dir, context.temp_allocator)
	fmt.sbprintf(sb, "%s bidi %v\n", sm.name, lv)
	br := font.line_breaks(s, sm.text, context.temp_allocator)
	fmt.sbprintf(sb, "%s breaks", sm.name)
	for b in br { fmt.sbprintf(sb, " %d%s", b.at, b.mandatory ? "!" : "") }
	fmt.sbprintf(sb, "\n")
}
