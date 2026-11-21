package filesearch_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import filesearch "gt:filesearch"
import "gt:fsx"

@(private = "file")
make_tree :: proc(t: ^testing.T, tag: string) -> string {
	base := fmt.tprintf("%s/gt_filesearch_%s_%d", fsx.temp_dir(context.temp_allocator), tag, os.get_pid())
	_ = fsx.remove_tree(base)
	_ = os.make_directory_all(fmt.tprintf("%s/src/models", base))
	_ = os.make_directory_all(fmt.tprintf("%s/docs", base))
	_ = os.write_entire_file(fmt.tprintf("%s/src/models/schema.odin", base), transmute([]u8)string("package models\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/src/models/alpha_item.odin", base), transmute([]u8)string("package models\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/src/models/beta_item.odin", base), transmute([]u8)string("package models\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/docs/readme.md", base), transmute([]u8)string("# readme\n"))
	testing.expect(t, os.exists(base), "fixture directory created")
	return strings.clone(base)
}

@(test)
typo_search_ranges_dirs_and_pagination :: proc(t: ^testing.T) {
	testing.expect(t, filesearch.available(), "built with GT_FILESEARCH=true")
	dir := make_tree(t, "typo")
	defer { _ = fsx.remove_tree(dir); delete(dir) }

	idx, err := filesearch.open({root = dir, watch = false})
	testing.expect_value(t, err, filesearch.Error.None)
	if err != .None { return }
	defer filesearch.close(idx)

	testing.expect(t, filesearch.wait_ready(idx, 10_000), "initial scan finished")
	st := filesearch.state(idx)
	testing.expect(t, !st.scanning && st.scanned >= 4, "scanned all fixture files")

	// Typo-tolerant query: "shcema" finds "schema.odin" with non-empty match ranges
	page, serr := filesearch.search(idx, "shcema", {limit = 10})
	defer filesearch.page_destroy(&page)
	testing.expect_value(t, serr, filesearch.Error.None)
	testing.expect(t, len(page.hits) >= 1 && strings.has_suffix(page.hits[0].path, "schema.odin"), "typo finds schema.odin")
	if len(page.hits) > 0 {
		testing.expect(t, len(page.hits[0].ranges) > 0, "files search returns match ranges")
	}

	// Mixed search (files + directories) finds the "models" directory
	mixed, merr := filesearch.search(idx, "models", {limit = 10, dirs = true})
	defer filesearch.page_destroy(&mixed)
	testing.expect_value(t, merr, filesearch.Error.None)
	found_dir := false
	for h in mixed.hits { if h.dir && strings.contains(h.path, "models") { found_dir = true } }
	testing.expect(t, found_dir, "mixed search includes directories")

	// Pagination returns distinct pages
	p1, _ := filesearch.search(idx, "item", {offset = 0, limit = 1})
	defer filesearch.page_destroy(&p1)
	p2, _ := filesearch.search(idx, "item", {offset = 1, limit = 1})
	defer filesearch.page_destroy(&p2)
	testing.expect(t, len(p1.hits) == 1 && len(p2.hits) == 1 && p1.hits[0].path != p2.hits[0].path, "pagination advances")
}

@(test)
frecency_boosts_opened_file :: proc(t: ^testing.T) {
	dir := make_tree(t, "frec")
	frec_dir := strings.concatenate({dir, "_frec"})
	defer { _ = fsx.remove_tree(dir); _ = fsx.remove_tree(frec_dir); delete(dir); delete(frec_dir) }

	idx, err := filesearch.open({root = dir, frecency_dir = frec_dir, watch = false})
	testing.expect_value(t, err, filesearch.Error.None)
	if err != .None { return }
	defer filesearch.close(idx)
	testing.expect(t, filesearch.wait_ready(idx, 10_000), "scan ready")

	// Open beta_item.odin several times; searching "item" must rank it ahead of alpha_item.odin
	for _ in 0 ..< 4 {
		testing.expect(t, filesearch.note_opened(idx, "src/models/beta_item.odin"), "note_opened succeeds")
	}
	page, serr := filesearch.search(idx, "item", {limit = 10})
	defer filesearch.page_destroy(&page)
	testing.expect_value(t, serr, filesearch.Error.None)
	testing.expect(t, len(page.hits) >= 2 && strings.has_suffix(page.hits[0].path, "beta_item.odin"), "frecency ranks beta_item first")
}

@(test)
watcher_picks_up_new_file :: proc(t: ^testing.T) {
	dir := make_tree(t, "watch")
	defer { _ = fsx.remove_tree(dir); delete(dir) }

	idx, err := filesearch.open({root = dir, watch = true})
	testing.expect_value(t, err, filesearch.Error.None)
	if err != .None { return }
	defer filesearch.close(idx)
	testing.expect(t, filesearch.wait_ready(idx, 10_000), "scan ready")

	// Wait for watcher to arm (bounded)
	arm_deadline := time.time_add(time.now(), 5 * time.Second)
	for !filesearch.state(idx).watching && time.diff(time.now(), arm_deadline) > 0 { time.sleep(20 * time.Millisecond) }

	fresh := fmt.tprintf("%s/docs/zebra_fresh_file.txt", dir)
	_ = os.write_entire_file(fresh, transmute([]u8)string("hello\n"))

	found := false
	deadline := time.time_add(time.now(), 5 * time.Second)
	for !found && time.diff(time.now(), deadline) > 0 {
		p, _ := filesearch.search(idx, "zebra_fresh", {limit = 5})
		for h in p.hits { if strings.has_suffix(h.path, "zebra_fresh_file.txt") { found = true } }
		filesearch.page_destroy(&p)
		if !found { time.sleep(30 * time.Millisecond) }
	}
	testing.expect(t, found, "watcher indexed newly created file")
}

@(test)
invalid_root_and_safe_close :: proc(t: ^testing.T) {
	idx, err := filesearch.open({root = "/nonexistent/gt_filesearch_missing_dir"})
	testing.expect_value(t, err, filesearch.Error.Invalid_Path)
	testing.expect_value(t, idx, filesearch.Index(0))
	filesearch.close(0)
	filesearch.close(filesearch.Index(999999))
}
