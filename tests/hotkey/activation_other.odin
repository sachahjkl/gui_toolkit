#+build !linux
package hotkey_test

import "core:testing"
import "../../src/platform"

// Windows has no launcher's activation token.
@(test)
the_activation_token_is_taken_from_the_environment :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.activation_token_from_env(context.temp_allocator), "")
}
