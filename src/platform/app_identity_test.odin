package platform

import "core:testing"

// The five programs' ids are what their shortcuts already carry: a change of the rule would split their taskbar groups.
@(test)
app_user_model_id_derives_the_programs_ids :: proc(t: ^testing.T) {
	testing.expect_value(t, app_user_model_id("Froment Software", "opencode native"), "FromentSoftware.OpencodeNative")
	testing.expect_value(t, app_user_model_id("Froment Software", "Papier"), "FromentSoftware.Papier")
	testing.expect_value(t, app_user_model_id("Froment Software", "cliche"), "FromentSoftware.Cliche")
	testing.expect_value(t, app_user_model_id("Froment Software", "OpenCode 2-go"), "FromentSoftware.OpenCode2Go")
	testing.expect_value(t, app_user_model_id("", "papier"), "Papier")
	testing.expect_value(t, app_user_model_id("Froment Software", " -"), "")
}
