package tk_changelog

// The changelog command of a project's tool, over the project (toolbox.Project): its CHANGELOG.md, its repository's
// releases for the versions' links, and its version line, which check compares with the last released version.
//   changelog new <type> <text> [-subject:<subject>]   one fragment; its name from the subject, else from the text
//   changelog check                                    every fragment well formed, the version the last released one
//   changelog preview                                  what the next version brings
//   changelog times                                    the versions with a day alone get their time, their tag's (git)

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import toolbox "../toolbox"

// The usage of the command, as its help says it.
COMMAND_USAGE :: "new <Added|Changed|Deprecated|Removed|Fixed|Security> <text> [-subject:<subject>] | check | preview | times: the fragments of changelog.d/, one per change a user can see; times gives the versions of before their time"

// The `changelog` command of a project's tool (`p` copied; its slices must live as long as the tool).
command :: proc(p: toolbox.Project) -> toolbox.Command {
	return {name = "changelog", usage = COMMAND_USAGE, run_with = command_run, user = new_clone(p)}
}

// What the project is to this package: its changelog's folder, its versions' link, its version line when it has one.
project_options :: proc(p: ^toolbox.Project) -> Project_Options {
	root := os.dir(p.changelog != "" ? p.changelog : "CHANGELOG.md")
	o := Project_Options{root = root != "" ? root : ".", user = p}
	if p.repository != "" { o.link = fmt.tprintf("%s/releases/tag/v%%s", p.repository) }
	if p.version_file != "" { o.version = project_version }
	return o
}

@(private = "file")
project_version :: proc(root: string, user: rawptr) -> string { return toolbox.project_version((^toolbox.Project)(user)^) }

// The versions of `root`'s CHANGELOG.md whose heading has their day alone ("## [1.2.0] - 2026-11-15") get their time, as
// the release writes it now ("2026-11-15 14:07", UTC): their tag's (`v1.2.0`, git's commit time). A version whose tag is
// not there, or another day than its heading's, is left as it is. `n`: the headings changed.
add_times :: proc(root: string) -> (n: int, why: string) {
	path := fmt.tprintf("%s/CHANGELOG.md", root)
	text, ok := read_text(path)
	if !ok { return 0, fmt.tprintf("%s cannot be read", path) }
	lines := split_lines(text)
	for &l in lines {
		version := heading_version(l)
		if version == "" { continue }
		_, _, rest := strings.partition(l, "] - ")
		day := strings.trim_space(rest)
		if len(day) != len("2026-11-15") { continue }   // (a time already, or no day)
		out, code := toolbox.capture({"git", "-C", root, "log", "-1", "--format=%ct", fmt.tprintf("v%s", version)})
		if code != 0 { continue }
		secs, parsed := strconv.parse_i64(strings.trim_space(out))
		if !parsed { continue }
		stamp := stamp_of(time.unix(secs, 0))
		if !strings.has_prefix(stamp, day) { continue }
		l = fmt.tprintf("## [%s] - %s", version, stamp)
		n += 1
	}
	if n == 0 { return 0, "" }
	if !write_text(path, strings.join(lines, "\n", context.temp_allocator)) { return 0, fmt.tprintf("%s cannot be written", path) }
	return n, ""
}

@(private = "file")
command_run :: proc(args: []string, user: rawptr) -> int {
	p := (^toolbox.Project)(user)
	o := project_options(p)
	what := len(args) > 0 ? args[0] : ""
	switch what {
	case "new":
		words := toolbox.plain_args(args[1:])
		if len(words) < 2 { break }
		text := strings.join(words[1:], " ", context.temp_allocator)
		path, why := new_fragment(o.root, words[0], toolbox.flag_value(args, "subject"), text)
		if why != "" { fmt.eprintfln("changelog: %s", why); return toolbox.EXIT_FAILED }
		fmt.println(path)
		return toolbox.EXIT_DONE
	case "check":
		if len(args) != 1 { break }
		errors, n := check(o)
		for e in errors { fmt.eprintfln("changelog: %s", e) }
		if len(errors) > 0 { return toolbox.EXIT_FAILED }
		fmt.printfln("changelog: %d fragments, well formed", n)
		return toolbox.EXIT_DONE
	case "times":
		if len(args) != 1 { break }
		n, why := add_times(o.root)
		if why != "" { fmt.eprintfln("changelog: %s", why); return toolbox.EXIT_FAILED }
		fmt.printfln("changelog: %d versions given their time", n)
		return toolbox.EXIT_DONE
	case "preview":
		if len(args) != 1 { break }
		text, errors := preview(o.root)
		for e in errors { fmt.eprintfln("changelog: %s", e) }
		if len(errors) > 0 { return toolbox.EXIT_FAILED }
		fmt.print(text != "" ? text : "changelog: no fragment, nothing to publish\n")
		return toolbox.EXIT_DONE
	}
	fmt.eprintfln("changelog %s", COMMAND_USAGE)
	return toolbox.EXIT_USAGE
}
