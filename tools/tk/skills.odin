package tk

// skills [<out>] [-check] [-zip:<file>]: the agent skills of skills/ (src/md/infrastructure/skills.md), each a SKILL.md
// and the references it names, copied from the repository when the command runs so that they cannot drift.
//   <out>          an HTTP catalog of opencode: <out>/index.json and <out>/<skill>/<file> (site_build writes it to skills/)
//   -zip:<file>    the same skills as a zip, <skill>/ at its root (tk demos writes gt-skills.zip for the release)
//   -check         reads and checks them, writes nothing (ci)
// The checks: each skill of SKILLS has its folder and each folder its skill; the frontmatter has a name (the folder's)
// and a description that a YAML reader takes as written; each `references/<file>` the text names has a source; the
// level that gt-plugin names ("API level <n>") is PLUGIN_API_LEVEL.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import archive "../../src/archive"
import toolbox "../../src/toolbox"

SKILLS_DIR :: "skills"
// The toolkit's version, the catalog's version of every skill: opencode downloads a skill again when it changes.
SKILLS_VERSION_SOURCE :: "src/ui/version.odin"
SKILLS_ZIP_NAME :: "gt-skills.zip"
// What a skill writes to name the plugin API's level: the check compares the number after it with PLUGIN_API_LEVEL.
SKILLS_LEVEL_FORM :: "API level "
// Claude Code and opencode both cut a longer description.
SKILLS_DESCRIPTION_MAX :: 1024

Skill_Def :: struct {
	name:        string,
	names_level: bool,   // its SKILL.md says the plugin API's level, in SKILLS_LEVEL_FORM
}

// The skills, in the catalog's order. A folder of skills/ that is not here is an error: a skill is published on purpose.
SKILLS :: [?]Skill_Def{
	{name = "gt-plugin", names_level = true},
	{name = "gui-toolkit"},
}

// A reference that is not a page of docs/ and its source. Every other `references/<name>.md` is docs/<name>.md; a name
// with neither is an error.
SKILL_SOURCES :: [?][2]string{
	{"gt.d.ts", "plugin-api/gt.d.ts"},
}

// A file of a skill: its path in the skill's folder ('/' between its parts) and its bytes.
Skill_File :: struct {
	path: string,
	data: []byte,
}

Skill :: struct {
	name:  string,
	files: []Skill_File,   // SKILL.md first, then its references in the order the text names them
}

run_skills :: proc(args: []string) -> string {
	root := toolkit_root()
	out := len(toolbox.plain_args(args)) > 0 ? toolbox.plain_args(args)[0] : ""
	zip := toolbox.flag_value(args, "zip")
	check := toolbox.has_flag(args, "check")
	if out == "" && zip == "" && !check { return "give a folder for the catalog, -zip:<file> or -check" }
	skills, version, why := skills_read(root, join({root, SKILLS_DIR}))
	if why != "" { return why }
	if out != "" {
		if why = skills_write_catalog(skills, version, out); why != "" { return why }
		fmt.printfln("the skills' catalog, version %s: %s", version, out)
	}
	if zip != "" {
		if why = skills_write_zip(skills, zip); why != "" { return why }
		fmt.printfln("packed %s", zip)
	}
	if check { fmt.printfln("skills ok: %d skills, version %s", len(skills), version) }
	return ""
}

// The skills of `skills_dir` (the folders of SKILLS) with their references from the repository at `root`, checked; the
// version of the catalog. `skills_dir` is apart from `root` so that a test checks a copy it broke.
skills_read :: proc(root, skills_dir: string) -> (skills: []Skill, version: string, why: string) {
	version, why = toolkit_version(root)
	if why != "" { return }
	level: int
	if level, why = plugin_api_level(root); why != "" { return }

	defs := SKILLS
	entries, err := os.read_all_directory_by_path(skills_dir, context.temp_allocator)
	if err != nil { return nil, "", fmt.tprintf("%s cannot be read: %v", skills_dir, err) }
	for e in entries {
		if e.type != .Directory { continue }
		known := false
		for d in defs { known ||= d.name == e.name }
		if !known { return nil, "", fmt.tprintf("%s/%s is not a skill of SKILLS (tools/tk/skills.odin)", skills_dir, e.name) }
	}

	out := make([dynamic]Skill, context.temp_allocator)
	for d in defs {
		s: Skill
		if s, why = skill_read(root, skills_dir, d, level); why != "" { return nil, "", why }
		append(&out, s)
	}
	return out[:], version, ""
}

@(private = "file")
skill_read :: proc(root, skills_dir: string, d: Skill_Def, level: int) -> (s: Skill, why: string) {
	path := join({skills_dir, d.name, "SKILL.md"})
	text, ok := read_text(path)
	if !ok { return {}, fmt.tprintf("%s cannot be read", path) }
	if why = skill_frontmatter_check(text, d.name); why != "" { return {}, fmt.tprintf("%s: %s", path, why) }
	if why = skill_level_check(text, d.names_level, level); why != "" { return {}, fmt.tprintf("%s: %s", path, why) }

	files := make([dynamic]Skill_File, context.temp_allocator)
	append(&files, Skill_File{path = "SKILL.md", data = transmute([]byte)text})
	for name in skill_references(text) {
		source := skill_source(root, name)
		if source == "" { return {}, fmt.tprintf("%s: references/%s has no source (SKILL_SOURCES in tools/tk/skills.odin, or docs/%s)", path, name, name) }
		data, rerr := os.read_entire_file(join({root, source}), context.temp_allocator)
		if rerr != nil { return {}, fmt.tprintf("%s: references/%s: %s cannot be read: %v", path, name, source, rerr) }
		append(&files, Skill_File{path = fmt.tprintf("references/%s", name), data = data})
	}
	return {name = d.name, files = files[:]}, ""
}

// The frontmatter between the first two lines "---": a `name` that is the folder's, and a `description`. Both are
// read as one line each, as written: a value that YAML would read otherwise (": " starts a mapping, " #" a comment, a
// quote a quoted scalar) is refused, since opencode and Claude Code read it as YAML.
skill_frontmatter_check :: proc(text, folder: string) -> string {
	body, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	if !strings.has_prefix(body, "---\n") { return "no frontmatter (a first line ---)" }
	end := strings.index(body[4:], "\n---")
	if end < 0 { return "the frontmatter has no end (a line ---)" }
	name, description: string
	for line in strings.split_lines(body[4:4 + end], context.temp_allocator) {
		switch {
		case strings.has_prefix(line, "name:"):        name = strings.trim_space(line[len("name:"):])
		case strings.has_prefix(line, "description:"): description = strings.trim_space(line[len("description:"):])
		}
	}
	if name == "" { return "the frontmatter has no name" }
	if name != folder { return fmt.tprintf("its name %q is not its folder's, %q (the id opencode and Claude Code give it)", name, folder) }
	if description == "" { return "the frontmatter has no description" }
	if len(description) > SKILLS_DESCRIPTION_MAX { return fmt.tprintf("its description has %d bytes, more than %d", len(description), SKILLS_DESCRIPTION_MAX) }
	if strings.contains(description, ": ") || strings.contains(description, " #") || strings.index_byte("\"'&*!|>%@`[{", description[0]) >= 0 {
		return "its description is not a plain YAML value (no \": \", no \" #\", no quote or sign first)"
	}
	return ""
}

// Each "API level <n>" of the text names PLUGIN_API_LEVEL; a skill that names the level names it once at least.
skill_level_check :: proc(text: string, names_level: bool, level: int) -> string {
	found := 0
	rest := text
	for {
		at := strings.index(rest, SKILLS_LEVEL_FORM)
		if at < 0 { break }
		rest = rest[at + len(SKILLS_LEVEL_FORM):]
		j := 0
		for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' { j += 1 }
		if j == 0 { continue }
		n, _ := strconv.parse_int(rest[:j])
		if n != level { return fmt.tprintf("it says %s%d, the API is at level %d (PLUGIN_API_LEVEL)", SKILLS_LEVEL_FORM, n, level) }
		found += 1
	}
	if names_level && found == 0 { return fmt.tprintf("it does not say the API's level as %q%d", SKILLS_LEVEL_FORM, level) }
	return ""
}

// The files the text names as `references/<file>`, each once, in the order it names them. A name is a file of the
// folder references/ itself: no '/' and no "..", so a catalog's paths stay inside the skill.
skill_references :: proc(text: string) -> []string {
	PREFIX :: "references/"
	path_byte :: proc(c: byte) -> bool { return c == '_' || c == '-' || c == '.' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
	out := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(text); {
		at := strings.index(text[i:], PREFIX)
		if at < 0 { break }
		start := i + at + len(PREFIX)
		i = start
		if start - len(PREFIX) > 0 && (path_byte(text[start - len(PREFIX) - 1]) || text[start - len(PREFIX) - 1] == '/') { continue }   // (x/references/: another folder's)
		j := start
		for j < len(text) && path_byte(text[j]) { j += 1 }
		for j > start && (text[j - 1] == '.' || text[j - 1] == '-') { j -= 1 }   // (the end of a sentence)
		name := text[start:j]
		if name == "" || name == "." || name == ".." || slice.contains(out[:], name) { continue }
		append(&out, name)
	}
	return out[:]
}

// The source of a reference, from the root: SKILL_SOURCES, else docs/<name> when it is a page there; "" for none.
skill_source :: proc(root, name: string) -> string {
	sources := SKILL_SOURCES
	for s in sources { if s[0] == name { return s[1] } }
	if strings.has_suffix(name, ".md") && os.exists(join({root, "docs", name})) { return fmt.tprintf("docs/%s", name) }
	return ""
}

// The catalog's index.json: each skill, the version, its files.
@(private = "file")
Catalog_Entry :: struct {
	name:    string,
	version: string,
	files:   []string,
}

@(private = "file")
Catalog :: struct {
	skills: []Catalog_Entry,
}

// <out>/index.json and <out>/<skill>/<file>, as opencode's HTTP catalog reads them (https://opencode.ai/docs/skills/).
skills_write_catalog :: proc(skills: []Skill, version, out: string) -> string {
	entries := make([]Catalog_Entry, len(skills), context.temp_allocator)
	for s, i in skills {
		paths := make([]string, len(s.files), context.temp_allocator)
		for f, k in s.files {
			paths[k] = f.path
			path := join({out, s.name, f.path})
			if why := skills_write_file(path, f.data); why != "" { return why }
		}
		entries[i] = {name = s.name, version = version, files = paths}
	}
	index, merr := json.marshal(Catalog{skills = entries}, {pretty = true}, context.temp_allocator)
	if merr != nil { return fmt.tprintf("the catalog's index cannot be written: %v", merr) }
	return skills_write_file(join({out, "index.json"}), index)
}

@(private = "file")
skills_write_file :: proc(path: string, data: []byte) -> string {
	if dir := path_dir_of(path); dir != "" {
		if err := os.make_directory_all(dir); err != nil && err != .Exist { return fmt.tprintf("cannot make %s: %v", dir, err) }
	}
	if err := os.write_entire_file(path, data); err != nil { return fmt.tprintf("cannot write %s: %v", path, err) }
	return ""
}

@(private = "file")
path_dir_of :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return i > 0 ? path[:i] : ""
}

// A zip with <skill>/<file> at its root: unpacked into ~/.config/opencode/skills or ~/.claude/skills, each folder is a
// skill. No index.json: a folder of skills has none.
skills_write_zip :: proc(skills: []Skill, zip: string) -> string {
	if dir := path_dir_of(zip); dir != "" { _ = os.make_directory_all(dir) }   // (a folder that cannot be made fails zip_begin)
	w: archive.Zip_Writer
	archive.zip_begin(&w, zip)
	for s in skills {
		for f in s.files { archive.zip_add(&w, fmt.tprintf("%s/%s", s.name, f.path), f.data) }
	}
	if err := archive.zip_end(&w); err != .None { return fmt.tprintf("%s cannot be written: %v", zip, err) }
	return ""
}

// The writes of tk demos and site_build: the skills of the checkout at `root`, read and checked, then written.
skills_catalog :: proc(root, out: string) -> string {
	skills, version, why := skills_read(root, join({root, SKILLS_DIR}))
	if why != "" { return why }
	return skills_write_catalog(skills, version, out)
}

skills_zip :: proc(root, zip: string) -> string {
	skills, _, why := skills_read(root, join({root, SKILLS_DIR}))
	if why != "" { return why }
	return skills_write_zip(skills, zip)
}

// The toolkit's version, the value of `VERSION :: "x.y.z"` in src/ui/version.odin.
toolkit_version :: proc(root: string) -> (version: string, why: string) {
	path := join({root, SKILLS_VERSION_SOURCE})
	text, ok := read_text(path)
	if !ok { return "", fmt.tprintf("%s cannot be read", path) }
	value := constant_value(text, "VERSION")
	if len(value) < 3 || value[0] != '"' || value[len(value) - 1] != '"' { return "", fmt.tprintf("%s has no VERSION :: \"x.y.z\"", path) }
	return value[1:len(value) - 1], ""
}

// PLUGIN_API_LEVEL of src/plugin_api/api.odin, the level a plugin of this toolkit is written for.
plugin_api_level :: proc(root: string) -> (level: int, why: string) {
	path := join({root, PLUGIN_API_SOURCE})
	text, ok := read_text(path)
	if !ok { return 0, fmt.tprintf("%s cannot be read", path) }
	n, parsed := strconv.parse_int(constant_value(text, "PLUGIN_API_LEVEL"))
	if !parsed || n < 1 { return 0, fmt.tprintf("%s has no PLUGIN_API_LEVEL :: <n>", path) }
	return n, ""
}

// The text after `NAME ::` on the line that declares it, up to a comment ("" when no line does).
@(private = "file")
constant_value :: proc(text, name: string) -> string {
	for line in strings.split_lines(text, context.temp_allocator) {
		rest := strings.trim_left_space(line)
		if !strings.has_prefix(rest, name) { continue }
		rest = strings.trim_left_space(rest[len(name):])
		if !strings.has_prefix(rest, "::") { continue }
		rest = rest[2:]
		if c := strings.index(rest, "//"); c >= 0 { rest = rest[:c] }
		return strings.trim_space(rest)
	}
	return ""
}
