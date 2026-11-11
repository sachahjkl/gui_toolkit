package tk_session

import "core:testing"

// A body run by unwatched.run keeps its test's name (its folder under build/session).
@(test)
an_anonymous_body_has_its_test_s_name :: proc(t: ^testing.T) {
	testing.expect_value(t, test_name("classeur::test_palette$anon-classeur:app_test.odin:62683"), "test_palette")
	testing.expect_value(t, test_name("test_browse"), "test_browse")
	testing.expect_value(t, test_name("pkg::a_test"), "a_test")
}
