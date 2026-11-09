#+build linux
package subpixel_system_test

// What the system says of text's colour stripes, on Linux: fontconfig's configuration. A process reads it once (FcInit), so this
// package holds this one test, its configuration given before anything opens fontconfig.

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../../src/font"

@(test)
the_stripes_are_fontconfig_s :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "gt_fc_*", context.temp_allocator)
	if !testing.expect(t, err == nil, "a folder") { return }
	defer os.remove_all(dir)
	conf, _ := filepath.join({dir, "fonts.conf"}, context.temp_allocator)
	data := `<?xml version="1.0"?><fontconfig><match target="pattern"><edit name="rgba" mode="assign"><const>bgr</const></edit></match></fontconfig>`
	testing.expect(t, os.write_entire_file(conf, transmute([]u8)string(data)) == nil, "its configuration")
	testing.expect(t, os.set_env("FONTCONFIG_FILE", conf) == nil, "given to fontconfig")
	testing.expect_value(t, font.system_subpixel_text(), font.Subpixel_Text.Bgr)
}
