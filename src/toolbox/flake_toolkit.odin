package tk_toolbox

// A program's flake and its toolkit. `nix run github:owner/program` fetches the program as a tarball, which holds no
// submodule: the package builds from a flake input `gui_toolkit` (flake = false) pinned to a commit instead of from
// ext/gui_toolkit. That commit is said twice, by the submodule and by flake.lock; the check holds them equal, so the
// package Nix builds is the program the tool builds. A program whose flake.lock has no `gui_toolkit` node is not
// checked. docs/toolbox.md, "The flake's toolkit".

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The flake input that carries the toolkit, and the lock file.
FLAKE_TOOLKIT_INPUT :: "gui_toolkit"
FLAKE_LOCK :: "flake.lock"

// The commit flake.lock pins the toolkit to; ok false when it pins none (no such node, or not a lock file).
flake_toolkit_pin :: proc(lock: string) -> (rev: string, ok: bool) {
	v, err := json.parse_string(lock, allocator = context.temp_allocator)
	if err != nil { return }
	root := v.(json.Object) or_return
	nodes := root["nodes"].(json.Object) or_return
	node := nodes[FLAKE_TOOLKIT_INPUT].(json.Object) or_return
	locked := node["locked"].(json.Object) or_return
	rev = locked["rev"].(json.String) or_return
	return rev, rev != ""
}

// The commit checked out in the git checkout at `dir` (a submodule's `.git` is a file that names its git folder; its
// HEAD is a commit, or a branch read from its refs).
checkout_head :: proc(dir: string) -> (rev: string, ok: bool) {
	git := fmt.tprintf("%s/.git", dir)
	if os.is_file(git) {
		text, err := os.read_entire_file_from_path(git, context.temp_allocator)
		if err != nil { return }
		line := strings.trim_space(string(text))
		if !strings.has_prefix(line, "gitdir:") { return }
		to := strings.trim_space(line[len("gitdir:"):])
		git = filepath.is_abs(to) ? to : fmt.tprintf("%s/%s", dir, to)
	}
	head, err := os.read_entire_file_from_path(fmt.tprintf("%s/HEAD", git), context.temp_allocator)
	if err != nil { return }
	h := strings.trim_space(string(head))
	if !strings.has_prefix(h, "ref:") { return h, len(h) == 40 }
	ref := strings.trim_space(h[len("ref:"):])
	if r, e := os.read_entire_file_from_path(fmt.tprintf("%s/%s", git, ref), context.temp_allocator); e == nil {
		return strings.trim_space(string(r)), true
	}
	packed, e := os.read_entire_file_from_path(fmt.tprintf("%s/packed-refs", git), context.temp_allocator)
	if e != nil { return }
	rest := string(packed)
	for l in strings.split_lines_iterator(&rest) {
		if space := strings.index_byte(l, ' '); space > 0 && l[space + 1:] == ref { return l[:space], true }
	}
	return
}

// Why the pin and the checkout differ ("": they agree). `head` "" : the checkout cannot be read.
flake_toolkit_says :: proc(pin, head: string) -> string {
	if head == "" { return "the toolkit's checkout has no commit to compare with flake.lock" }
	if pin == head { return "" }
	return fmt.tprintf("flake.lock pins %s at %s, the submodule is at %s: set the input's url to github:sachahjkl/gui_toolkit/%s in flake.nix, then nix flake lock", FLAKE_TOOLKIT_INPUT, pin[:min(8, len(pin))], head[:min(8, len(head))], head)
}

// The check of a program in `root`: its flake.lock's toolkit is its submodule's commit. A program that pins none,
// or a tool pointed at another checkout ($GT), passes.
flake_toolkit_check :: proc(p: Project, root := ".") -> bool {
	lock, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s", root, FLAKE_LOCK), context.temp_allocator)
	if err != nil { return true }
	pin, pinned := flake_toolkit_pin(string(lock))
	if !pinned { return true }
	if p.toolkit == "" && os.get_env(TOOLKIT_ENV, context.temp_allocator) != "" { return true }
	dir := toolkit_dir(p)
	head, _ := checkout_head(filepath.is_abs(dir) ? dir : fmt.tprintf("%s/%s", root, dir))
	if why := flake_toolkit_says(pin, head); why != "" {
		fmt.eprintfln("check: %s", why)
		return false
	}
	return true
}
