package tk_licence

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../fsx"
import signing "../signing"

@(private = "file")
STORE_PRODUCT :: Product{
	name           = "sample",
	title          = "Sample",
	version_tag    = "SAMPLE1",
	sign_context   = "sample-licence-v1\n",
	file_extension = ".samplelicence",
	public_key     = "V91HlwwFnqUMQs402LFbpG21HljQ6QrKRpc81zDVXLo",   // the "other" pair of licence_test.odin, as the release key
	dev_public_key = "zHs7wxUEefqH37-vN5cKoTnZOCCFBnmcoQGrw6i3UAk",
	editions       = {0 = {id = "supporter", title = "Supporter"}},
	update_years   = 2,
}
@(private = "file") STORE_DEV_SEED     :: "Z3QtbGljZW5jZS1zYW1wbGUtZGV2LXNlZWQtMDAwMSE"
@(private = "file") STORE_RELEASE_SEED :: "Z3QtbGljZW5jZS1vdGhlci1zYW1wbGUtc2VlZC0wMiE"

@(private = "file")
issued :: proc(seed_text: string) -> string {
	seed, _ := signing.key_decode(seed_text)
	text, ok := sign(STORE_PRODUCT, seed[:], {edition = "supporter", name = "Jeanne Dupont", email = "jeanne@example.org", date = "2026-10-22", order = "SAMPLE-0001"}, context.temp_allocator)
	assert(ok)
	return text
}

// A folder of its own under the temporary one, removed by the caller.
@(private = "file")
scratch :: proc(name: string) -> string {
	dir, _ := filepath.join({fsx.temp_dir(context.temp_allocator), fmt.tprintf("gt-licence-%s-%d", name, os.get_pid())}, context.temp_allocator)
	_ = fsx.remove_tree(dir)
	fsx.make_dirs(dir)
	return dir
}

@(test)
store_install_read_remove :: proc(t: ^testing.T) {
	dir := scratch("file")
	defer fsx.remove_tree(dir)
	path, _ := filepath.join({dir, "sub", "licence.samplelicence"}, context.temp_allocator)
	s := new(Store)
	defer free(s)
	store_init(s, {product = STORE_PRODUCT, path = path, released = "2027-01-01"})
	defer store_destroy(s)

	st := store_read(s, context.temp_allocator)
	testing.expect(t, !st.stored && !st.registered)

	// a development licence is refused by a release store, and nothing is written
	testing.expect_value(t, store_install(s, issued(STORE_DEV_SEED)), Error.Bad_Signature)
	testing.expect_value(t, fsx.path_kind(path), fsx.Path_Kind.Absent)

	// the release's licence, wrapped as in a mail: kept as the key alone
	key := issued(STORE_RELEASE_SEED)
	testing.expect_value(t, store_install(s, strings.concatenate({"# a comment\n  ", key[:40], "\n", key[40:], "\n"}, context.temp_allocator)), Error.None)
	data, _ := fsx.read_all(path, context.temp_allocator)
	testing.expect_value(t, string(data), strings.concatenate({key, "\n"}, context.temp_allocator))
	st = store_read(s, context.temp_allocator)
	testing.expect(t, st.registered && st.covered)
	testing.expect_value(t, st.licence.name, "Jeanne Dupont")
	testing.expect_value(t, st.licence.updates_until, "2028-10-22")
	// what crosses from a task to the interface is owned by the allocator given
	owned := store_read(s, context.allocator)
	testing.expect_value(t, owned.licence.order, "SAMPLE-0001")
	status_destroy(&owned)
	testing.expect(t, !owned.registered && owned.licence.name == "")

	// a version released after its years of updates: registered, not covered
	delete(s.options.released, runtime.heap_allocator())   // (the store owns its strings)
	s.options.released = strings.clone("2029-01-01", runtime.heap_allocator())
	st = store_read(s, context.temp_allocator)
	testing.expect(t, st.registered && !st.covered)

	// a file that is no licence, then a damaged one on the disk: stored, not registered
	testing.expect_value(t, store_install(s, "hello"), Error.Bad_Format)
	_ = os.write_entire_file(path, transmute([]byte)string("SAMPLE1.aaaa.bbbb\n"))
	st = store_read(s, context.temp_allocator)
	testing.expect(t, st.stored && !st.registered)
	testing.expect_value(t, st.err, Error.Bad_Signature)

	testing.expect(t, store_remove(s))
	testing.expect_value(t, fsx.path_kind(path), fsx.Path_Kind.Absent)
	testing.expect(t, store_remove(s), "removing nothing is done")
}

@(test)
store_install_file_and_dev :: proc(t: ^testing.T) {
	dir := scratch("dev")
	defer fsx.remove_tree(dir)
	path, _ := filepath.join({dir, "licence.samplelicence"}, context.temp_allocator)
	file, _ := filepath.join({dir, "Jeanne.samplelicence"}, context.temp_allocator)
	s := new(Store)
	defer free(s)
	store_init(s, {product = STORE_PRODUCT, path = path, accept_dev = true})
	defer store_destroy(s)

	dev := issued(STORE_DEV_SEED)
	lic: Licence
	_ = os.write_entire_file(file, transmute([]byte)file_text(STORE_PRODUCT, lic, dev, allocator = context.temp_allocator))
	testing.expect(t, is_licence_file(STORE_PRODUCT, file))
	testing.expect(t, is_licence_file(STORE_PRODUCT, "C:\\x\\A.SampleLicence"))
	testing.expect(t, !is_licence_file(STORE_PRODUCT, ".samplelicence.txt"))
	testing.expect_value(t, store_install_file(s, file), Error.None)
	st := store_read(s, context.temp_allocator)
	testing.expect(t, st.registered, "a development store takes the development pair")
	testing.expect_value(t, store_install_file(s, fmt.tprintf("%s/none", dir)), Error.Not_Read)
	big := strings.repeat("A", MAX_TEXT + 10, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]byte)big)
	testing.expect_value(t, store_install_file(s, file), Error.Too_Long)

	d := file_dialog(STORE_PRODUCT, "Choose a licence file", "Sample licence")
	testing.expect_value(t, d.filters[0].patterns[0], "*.samplelicence")
}

@(test)
store_seed_once :: proc(t: ^testing.T) {
	dir := scratch("seed")
	defer fsx.remove_tree(dir)
	path, _ := filepath.join({dir, "licence.samplelicence"}, context.temp_allocator)
	key := issued(STORE_RELEASE_SEED)
	s := new(Store)
	defer free(s)
	store_init(s, {product = STORE_PRODUCT, path = path, seed = key})
	defer store_destroy(s)

	st := store_read(s, context.temp_allocator)
	testing.expect(t, st.registered, "the build's licence is put in place")
	testing.expect(t, fsx.path_kind(strings.concatenate({path, SEED_MARKER}, context.temp_allocator)) == .File)
	// removed: it stays removed
	testing.expect(t, store_remove(s))
	st = store_read(s, context.temp_allocator)
	testing.expect(t, !st.stored)

	// a store that holds a licence keeps its own; a seed the store does not accept goes nowhere
	other_dir := scratch("seed-refused")
	defer fsx.remove_tree(other_dir)
	other_path, _ := filepath.join({other_dir, "licence.samplelicence"}, context.temp_allocator)
	r := new(Store)
	defer free(r)
	store_init(r, {product = STORE_PRODUCT, path = other_path, seed = issued(STORE_DEV_SEED)})
	defer store_destroy(r)
	st = store_read(r, context.temp_allocator)
	testing.expect(t, !st.stored)
	testing.expect_value(t, fsx.path_kind(other_path), fsx.Path_Kind.Absent)
}

@(test)
store_in_memory :: proc(t: ^testing.T) {
	key := issued(STORE_RELEASE_SEED)
	s := new(Store)
	defer free(s)
	store_init(s, {product = STORE_PRODUCT, memory = true, seed = key})
	defer store_destroy(s)
	p := store_path(s, context.temp_allocator)
	testing.expect_value(t, p, "")
	st := store_read(s, context.temp_allocator)
	testing.expect(t, st.registered, "seeded once per run")
	testing.expect(t, store_remove(s))
	st = store_read(s, context.temp_allocator)
	testing.expect(t, !st.stored, "and not again in the same run")
	testing.expect_value(t, store_install(s, key), Error.None)
	st = store_read(s, context.temp_allocator)
	testing.expect(t, st.registered)
}

@(test)
store_default_path :: proc(t: ^testing.T) {
	s := new(Store)
	defer free(s)
	store_init(s, {product = STORE_PRODUCT, program = "gt-licence-sample"})
	defer store_destroy(s)
	p := store_path(s, context.temp_allocator)
	if p == "" { return }   // (a system with no configuration folder: nothing to say)
	testing.expect(t, strings.has_suffix(p, "licence.samplelicence"), p)
	testing.expect(t, strings.contains(p, "gt-licence-sample"), p)
}
