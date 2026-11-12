package tk_toolbox

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file") ABC_SHA256 :: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
@(private = "file") EMPTY_SHA256 :: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
// What a run past its limit takes at most, for a command that would take a minute.
@(private = "file") LIMIT :: 300 * time.Millisecond
@(private = "file") LIMIT_SLACK :: 20 * time.Second

// A shell command line, on this system's shell.
@(private = "file")
shell :: proc(line: string) -> []string {
	when ODIN_OS == .Windows {
		return slice_with({"cmd", "/c"}, line)
	} else {
		return slice_with({"sh", "-c"}, line)
	}
}

// A new empty folder of this test's, under the system's temporary folder.
@(private = "file")
temp_folder :: proc(t: ^testing.T, name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, fmt.tprintf("tk_toolbox_%s_%d", name, os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, dir)
	return dir
}

@(private = "file")
file_url :: proc(path: string) -> string {
	slashes, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return strings.has_prefix(slashes, "/") ? fmt.tprintf("file://%s", slashes) : fmt.tprintf("file:///%s", slashes)
}

@(test)
sha256_of_bytes_and_of_a_file :: proc(t: ^testing.T) {
	testing.expect_value(t, sha256_hex(transmute([]byte)string("abc")), ABC_SHA256)
	testing.expect_value(t, sha256_hex(nil), EMPTY_SHA256)
	dir := temp_folder(t, "hash")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/abc.txt", dir)
	_ = os.write_entire_file(path, transmute([]byte)string("abc"))
	sum, ok := sha256_file(path)
	testing.expect(t, ok)
	testing.expect_value(t, sum, ABC_SHA256)
	_, ok = sha256_file(fmt.tprintf("%s/missing.txt", dir))
	testing.expect(t, !ok, "a file that is not there has no sum")
}

@(test)
an_environment_with_and_without :: proc(t: ^testing.T) {
	testing.expect(t, os.set_env("TK_TOOLBOX_KEPT", "1") == nil)
	testing.expect(t, os.set_env("TK_TOOLBOX_DROPPED", "1") == nil)
	testing.expect(t, os.set_env("TK_TOOLBOX_REPLACED", "old") == nil)
	defer { _ = os.unset_env("TK_TOOLBOX_KEPT"); _ = os.unset_env("TK_TOOLBOX_DROPPED"); _ = os.unset_env("TK_TOOLBOX_REPLACED") }
	env := env_with({"TK_TOOLBOX_DROPPED"}, "TK_TOOLBOX_REPLACED=new", "TK_TOOLBOX_ADDED=yes")
	count :: proc(env: []string, entry: string) -> (n: int) {
		for e in env { if e == entry { n += 1 } }
		return
	}
	named :: proc(env: []string, name: string) -> (n: int) {
		for e in env { if env_name(e) == name { n += 1 } }
		return
	}
	testing.expect_value(t, count(env, "TK_TOOLBOX_KEPT=1"), 1)
	testing.expect_value(t, named(env, "TK_TOOLBOX_DROPPED"), 0)
	testing.expect_value(t, named(env, "TK_TOOLBOX_REPLACED"), 1)
	testing.expect_value(t, count(env, "TK_TOOLBOX_REPLACED=new"), 1)
	testing.expect_value(t, count(env, "TK_TOOLBOX_ADDED=yes"), 1)
	testing.expect_value(t, env_name("=C:=C:\\work"), "")
	testing.expect_value(t, env_name("PATH=/bin"), "PATH")
	when ODIN_OS == .Windows {
		testing.expect_value(t, named(env_with({"tk_toolbox_kept"}), "TK_TOOLBOX_KEPT"), 0)
	} else {
		testing.expect_value(t, named(env_with({"tk_toolbox_kept"}), "TK_TOOLBOX_KEPT"), 1)
	}
}

@(test)
the_exit_code_of_a_process :: proc(t: ^testing.T) {
	testing.expect_value(t, exit_code({exited = false}), -1)
	testing.expect_value(t, exit_code({exited = true, exit_code = 3}), 3)
	testing.expect(t, succeeded({exited = true, exit_code = 0, success = true}))
	testing.expect(t, !succeeded({exited = true, exit_code = 1, success = true}), "Windows says success for any code")
	testing.expect(t, !succeeded({exited = false}))
	when ODIN_OS == .Windows {
		testing.expect_value(t, exit_code({exited = true, exit_code = 0xFFFF_FFFF}), -1)
		testing.expect_value(t, exit_code({exited = true, exit_code = 0xC000_0005}), int(i32(-1073741819)))
	}
	_, code := capture(shell("exit 7"))
	testing.expect_value(t, code, 7)
}

@(test)
a_command_run :: proc(t: ^testing.T) {
	testing.expect(t, run(shell("exit 0")))
	testing.expect(t, !run(shell("exit 3")), "a code of its own is a failure")
	testing.expect(t, !run({"tk-toolbox-no-such-program"}), "nothing to start")
	testing.expect(t, !run(nil), "no command")

	dir := temp_folder(t, "run")
	defer os.remove_all(dir)
	log := fmt.tprintf("%s/log.txt", dir)
	_ = os.write_entire_file(log, transmute([]byte)string("before\n"))
	testing.expect(t, run(shell("echo out && echo err 1>&2"), {log = log, echo = true}))
	data, _ := os.read_entire_file(log, context.temp_allocator)
	text := string(data)
	testing.expect(t, strings.has_prefix(text, "before\n> "), text)
	testing.expect(t, strings.contains(text, "out") && strings.contains(text, "err"), text)

	began := time.tick_now()
	when ODIN_OS == .Windows {
		over := run({"ping", "-n", "60", "127.0.0.1"}, {limit = LIMIT, log = log})
	} else {
		over := run({"sleep", "60"}, {limit = LIMIT, log = log})
	}
	testing.expect(t, !over, "past its limit: a failure")
	testing.expect(t, time.tick_since(began) < LIMIT_SLACK, "stopped, not waited for")
}

@(test)
a_command_captured :: proc(t: ^testing.T) {
	dir := temp_folder(t, "capture")
	defer os.remove_all(dir)
	when ODIN_OS == .Windows {
		line := "echo %TK_TOOLBOX_SEEN%&& cd"
	} else {
		line := "echo $TK_TOOLBOX_SEEN && pwd"
	}
	out, code := capture(shell(line), {dir = dir, env = env_with(nil, "TK_TOOLBOX_SEEN=seen")})
	testing.expect_value(t, code, 0)
	lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, strings.trim_space(lines[0]), "seen")
		testing.expect_value(t, filepath.base(strings.trim_space(lines[1])), filepath.base(dir))
	}
	_, code = capture({"tk-toolbox-no-such-program"})
	testing.expect_value(t, code, -1)
}

// Offline: a file as pinned is kept, a file: URL is fetched and checked, a file that does not match is refused and removed.
@(test)
a_pinned_file :: proc(t: ^testing.T) {
	dir := temp_folder(t, "pinned")
	defer os.remove_all(dir)
	have := fmt.tprintf("%s/have.txt", dir)
	_ = os.write_entire_file(have, transmute([]byte)string("abc"))
	// as pinned: kept, nothing fetched (the address would not answer)
	testing.expect_value(t, download_pinned("https://invalid.invalid/abc", have, ABC_SHA256, quiet = true), "")
	data, _ := os.read_entire_file(have, context.temp_allocator)
	testing.expect_value(t, string(data), "abc")

	src := fmt.tprintf("%s/src.txt", dir)
	_ = os.write_entire_file(src, transmute([]byte)string("abc"))
	got := fmt.tprintf("%s/sub/got.txt", dir)
	testing.expect_value(t, download_pinned(file_url(src), got, ABC_SHA256, quiet = true), "")
	data, _ = os.read_entire_file(got, context.temp_allocator)
	testing.expect_value(t, string(data), "abc")

	// a file there that is not as pinned is fetched again
	_ = os.write_entire_file(got, transmute([]byte)string("old"))
	log := fmt.tprintf("%s/log.txt", dir)
	testing.expect_value(t, download_pinned(file_url(src), got, ABC_SHA256, log = log), "")
	said, _ := os.read_entire_file(log, context.temp_allocator)
	testing.expect(t, strings.contains(string(said), "downloading file:"), string(said))

	_ = os.write_entire_file(src, transmute([]byte)string("abd"))
	bad := fmt.tprintf("%s/bad.txt", dir)
	why := download_pinned(file_url(src), bad, ABC_SHA256, quiet = true)
	testing.expect(t, strings.contains(why, "SHA-256 mismatch"), why)
	testing.expect(t, !os.exists(bad), "the file that does not match is gone")
}

// What GitHub's API says of a release: the id of the asset by its name, whatever the order, as an integer or a float.
@(test)
a_release_names_its_assets :: proc(t: ^testing.T) {
	release := `{"tag_name":"v1","assets":[{"id":11,"name":"a.zip"},{"id":705909133,"name":"odin-linux-amd64-dev.tar.gz"},{"id":12.0,"name":"b.zip"}]}`
	testing.expect_value(t, release_asset_id(release, "odin-linux-amd64-dev.tar.gz"), "705909133")
	testing.expect_value(t, release_asset_id(release, "b.zip"), "12")
	testing.expect_value(t, release_asset_id(release, "missing.zip"), "")
	testing.expect_value(t, release_asset_id("not json", "a.zip"), "")
}

// Only a file of a GitHub release goes through the API; anything else is not asked of it (and nothing is written).
@(test)
only_a_release_goes_through_the_api :: proc(t: ^testing.T) {
	dir := temp_folder(t, "api")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/not_a_release.bin", dir)
	testing.expect(t, !download_through_api("https://example.com/a/b/releases/download/v1/x.zip", path, quiet = true), "another host")
	testing.expect(t, !download_through_api("https://github.com/owner/repo/archive/refs/tags/v1.zip", path, quiet = true), "not a release's file")
	testing.expect(t, !os.exists(path), "nothing written")
}

// A picture's width from its header: a PNG's, and a WebP's of each kind (lossy, lossless, extended); anything else is not one.
@(test)
a_picture_says_its_width :: proc(t: ^testing.T) {
	png := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0x05, 0xb3, 0, 0, 0x03, 0x98}
	riff :: proc(kind: string, rest: []u8) -> []u8 {
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, "RIFF")
		append(&b, 0, 0, 0, 0)
		append(&b, "WEBP")
		append(&b, kind)
		append(&b, 0, 0, 0, 0)
		append(&b, ..rest)
		for len(b) < 30 { append(&b, 0) }
		return b[:]
	}
	lossy := riff("VP8 ", {0, 0, 0, 0x9d, 0x01, 0x2a, 0xb3, 0x05, 0x98, 0x03})        // (frame tag, start code, 1459 then 920)
	lossless := riff("VP8L", {0x2f, 0xb2, 0x05, 0, 0})                                // (1459 - 1 in its first 14 bits)
	extended := riff("VP8X", {0, 0, 0, 0, 0xb2, 0x05, 0, 0x97, 0x03, 0})               // (flags, then 1459 - 1 and 920 - 1)
	for c in ([][]u8{png, lossy, lossless, extended}) {
		w, ok := image_width(c)
		testing.expect(t, ok && w == 1459, "1459 pixels wide")
	}
	_, ok := image_width(transmute([]u8)string("GIF89a and the rest of a picture"))
	testing.expect(t, !ok, "not a PNG or a WebP")
}
