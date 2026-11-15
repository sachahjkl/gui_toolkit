package tk_secrets

import "core:fmt"
import "core:log"
import "core:testing"
import "core:time"

@(private = "file") TEST_APP :: "gui-toolkit-secrets-test"

@(test)
a_value_in_clear_is_not_sealed :: proc(t: ^testing.T) {
	for field in ([]string{"", "hunter2", "dpapi:", "secret-service:v1", "DPAPI:v1:AAAA"}) {
		secret, result := open(TEST_APP, field)
		testing.expect_value(t, result, Open_Result.Not_Sealed)
		testing.expect_value(t, secret, "")
	}
}

// A field of the other system's mark is seal's work: Refused, never read as a password in clear.
@(test)
the_other_systems_field_is_refused :: proc(t: ^testing.T) {
	other := DPAPI_MARK + "AQAAANCMnd8BFdERjHoAwE/Cl+s=" when ODIN_OS != .Windows else SERVICE_MARK + "a name"
	secret, result := open(TEST_APP, other)
	testing.expect_value(t, result, Open_Result.Refused)
	testing.expect_value(t, secret, "")
}

// A field of this system's mark that stands for nothing: Refused.
@(test)
a_broken_field_is_refused :: proc(t: ^testing.T) {
	broken := DPAPI_MARK + "!!not base64" when ODIN_OS == .Windows else SERVICE_MARK
	_, result := open(TEST_APP, broken)
	testing.expect_value(t, result, Open_Result.Refused)
}

// The test that breaks the design first: a secret sealed comes back whole, and once forgotten (Linux) it is gone.
@(test)
a_secret_goes_round :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows && ODIN_OS != .Linux {
		_, none := seal(TEST_APP, "a name", "a secret")   // (a `when` opens no scope: a name of its own)
		testing.expect_value(t, none, Seal_Result.Unavailable)
		testing.expect(t, !available())
		return
	}
	if !available() {
		log.info("no Secret Service on this session: the round trip is skipped")
		return
	}
	// (a name of this run: a run that died before its forget leaves nothing the next one finds)
	name := fmt.tprintf("round trip %d", time.to_unix_nanoseconds(time.now()))
	secret :: "p@ss wörd\x00 with a NUL"
	field, sealed := seal(TEST_APP, name, secret, context.temp_allocator)
	if sealed == .Unavailable && ODIN_OS == .Linux {
		log.info("the Secret Service's keyring is locked: the round trip is skipped")
		return
	}
	testing.expect_value(t, sealed, Seal_Result.Sealed)
	testing.expect(t, is_sealed(field))
	testing.expect(t, field != secret)
	back, opened := open(TEST_APP, field, context.temp_allocator)
	testing.expect_value(t, opened, Open_Result.Opened)
	testing.expect_value(t, back, secret)
	when ODIN_OS == .Linux {
		_, other := open("another-app", field)
		testing.expect_value(t, other, Open_Result.Refused)   // (the item is the program's)
		forget(TEST_APP, field)
		_, after := open(TEST_APP, field)
		testing.expect_value(t, after, Open_Result.Refused)
	}
}
