package tk_changelog

// The changelog command of a project's tool, over the project (toolbox.Project): its CHANGELOG.md, its repository's
// releases for the versions' links, and its version line, which check compares with the last released version.
//   changelog new <type> <text> [-subject:<subject>]   one fragment; its name from the subject, else from the text
//   changelog check                                    every fragment well formed, the version the last released one
//   changelog preview                                  what the next version brings

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "../toolbox"

// The usage of the command, as its help says it.
COMMAND_USAGE :: "new <Added|Changed|Deprecated|Removed|Fixed|Security> <text> [-subject:<subject>] | check | preview: the fragments of changelog.d/, one per change a user can see"

// The `changelog` command of a project's tool (`p` copied; its slices must live as long as the tool).
command :: proc(p: toolbox.Project) -> toolbox.Command {
	return {name = "changelog", usage = COMMAND_USAGE, run_with = command_run, user = new_clone(p)}
}

// What the project is to this package: its changelog's folder, its versions' link, its version line when it has one.
project_options :: proc(p: ^toolbox.Project) -> Options {
	root := os.dir(p.changelog != "" ? p.changelog : "CHANGELOG.md")
	o := Options{root = root != "" ? root : ".", user = p}
	if p.repository != "" { o.link = fmt.tprintf("%s/releases/tag/v%%s", p.repository) }
	if p.version_file != "" { o.version = project_version }
	return o
}

@(private = "file")
project_version :: proc(root: string, user: rawptr) -> string { return toolbox.project_version((^toolbox.Project)(user)^) }

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
