package store_test

import "core:testing"
import store "gt:store"

// Kept values: read once as numbers (clamped; a line that is no number left out), a value at its rest forgotten and its
// line gone from the file, another kept and written so that it reads back the same.
@(test)
kept_values_forget_their_rest :: proc(t: ^testing.T) {
	file: store.Store   // (in memory: no path)
	defer store.close(&file)
	store.set(&file, "a", "1.5")
	store.set(&file, "b", "9")      // (past most: clamped)
	store.set(&file, "c", "wide")   // (no number: left out)
	k: store.Kept
	defer store.kept_destroy(&k)
	store.kept_load(&k, &file, 0.5, 3)
	testing.expect_value(t, store.kept_of(&k, "a", 1), 1.5)
	testing.expect_value(t, store.kept_of(&k, "b", 1), 3)
	testing.expect_value(t, store.kept_of(&k, "c", 1), 1)
	testing.expect_value(t, store.kept_of(&k, "none", 1.25), 1.25)

	store.kept_set(&k, "a", 1, 1)   // (back to its rest: forgotten, it follows the rest)
	testing.expect_value(t, store.kept_of(&k, "a", 2), 2)
	_, has := store.get(&file, "a")
	testing.expect(t, !has, "its line went")

	store.kept_set(&k, "d", 1.1, 1)
	v, ok := store.get(&file, "d")
	testing.expect(t, ok && v == "1.1", "kept and written so that it reads back the same")
	again: store.Kept
	defer store.kept_destroy(&again)
	store.kept_load(&again, &file, 0.5, 3)
	testing.expect_value(t, store.kept_of(&again, "d", 1), 1.1)

	store.kept_forget(&k, "d")
	testing.expect_value(t, store.kept_of(&k, "d", 1), 1)
	_, has = store.get(&file, "d")
	testing.expect(t, !has, "forgotten: its line went")
}
