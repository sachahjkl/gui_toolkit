#+build linux
package hotkey_test

import "core:os"
import "core:testing"
import "../../src/platform"

// The launcher's activation token is read once and taken out of the environment.
@(test)
the_activation_token_is_taken_from_the_environment :: proc(t: ^testing.T) {
	_ = os.set_env("XDG_ACTIVATION_TOKEN", "abc123")
	tok := platform.activation_token_from_env(context.temp_allocator)
	testing.expect_value(t, tok, "abc123")
	testing.expect_value(t, os.get_env("XDG_ACTIVATION_TOKEN", context.temp_allocator), "")
	testing.expect_value(t, platform.activation_token_from_env(context.temp_allocator), "")
}
