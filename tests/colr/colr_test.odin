// Tests of the COLR interpreter: the color-fonts test glyphs against Direct2D, Noto Color Emoji (tools\fetch_emoji.ps1
// puts it in build\emoji; the tests that need it are skipped without it) shaped and drawn.
package colr_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../font"

COLRV1 :: #load("../color_glyphs/data/test_glyphs-glyf_colr_1.ttf")

EMOJI_DIR :: #config(EMOJI_DIR, "build/emoji")

emoji_font :: proc() -> (data: []byte, ok: bool) {
	d, err := os.read_entire_file(fmt.tprintf("%s/NotoColorEmoji-COLRv1.ttf", EMOJI_DIR), context.allocator)
	return d, err == nil
}

// The fully qualified sequences of emoji-test.txt, as UTF-8.
emoji_sequences :: proc() -> (list: []string, ok: bool) {
	data, err := os.read_entire_file(fmt.tprintf("%s/emoji-test.txt", EMOJI_DIR), context.allocator)
	if err != nil { return nil, false }
	out := make([dynamic]string)
	for line in strings.split_lines(string(data)) {
		if len(line) == 0 || line[0] == '#' || !strings.contains(line, "; fully-qualified") { continue }
		sb := strings.builder_make()
		for tok in strings.fields(line[:strings.index_byte(line, ';')]) {
			v, _ := strconv.parse_int(tok, 16)
			strings.write_rune(&sb, rune(v))
		}
		append(&out, strings.to_string(sb))
	}
	return out[:], true
}

// Every emoji of Unicode's list shaped with the font alone: one glyph each (a ligature for sequences), not .notdef.
@(test)
emoji_sequences_shape_to_one_glyph :: proc(t: ^testing.T) {
	data, ok := emoji_font()
	if !ok { fmt.println("skipped: build/emoji/NotoColorEmoji-COLRv1.ttf is missing (tools\\fetch_emoji.ps1)"); return }
	seqs, ok2 := emoji_sequences()
	if !ok2 { fmt.println("skipped: emoji-test.txt is missing (tools\\fetch_emoji.ps1 -Unicode)"); return }
	s: font.State
	font.init(&s)
	defer font.destroy(&s)
	id, loaded := font.load_embedded(&s, data)
	testing.expect(t, loaded)
	cas := font.cascade(&s, {{font = id}}, nil, true)
	bad := 0
	for q in seqs {
		sh := font.shape(&s, cas, 32, q, {}, context.temp_allocator)
		one := len(sh.glyphs) == 1 && sh.glyphs[0].id != 0 && sh.glyphs[0].face == id
		if !one {
			bad += 1
			if bad <= 12 {
				cps := make([dynamic]string, context.temp_allocator)
				for r in q { append(&cps, fmt.tprintf("%X", u32(r))) }
				fmt.printf("not one glyph: %s -> %d glyphs\n", strings.join(cps[:], " ", context.temp_allocator), len(sh.glyphs))
			}
		}
	}
	fmt.printf("%d sequences, %d not shaped to one glyph\n", len(seqs), bad)
	testing.expectf(t, bad == 0, "%d of %d emoji sequences are not one glyph", bad, len(seqs))
}
