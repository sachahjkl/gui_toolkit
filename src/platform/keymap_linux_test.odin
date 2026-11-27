#+build linux
package platform

import "core:testing"

// AltGr is no Alt: it chooses a level of the layout (AltGr+E types € in French). Named Alt, a tap of it alone lit a menu
// bar and showed its access letters (ui/menu_bar.odin).
@(test)
altgr_is_no_alt :: proc(t: ^testing.T) {
	testing.expect_value(t, key_from_keysym(Xkb_Keysym(0xfe03)), Key.None)   // ISO_Level3_Shift
	testing.expect_value(t, key_from_keysym(Xkb_Keysym(0xffe9)), Key.Alt)    // Alt_L
	testing.expect_value(t, key_from_keysym(Xkb_Keysym(0xffea)), Key.Alt)    // Alt_R
}
