package showcase

// The values scene: the control a value gets from its nature. A person chooses how a value is stored, what it is (its
// value kind), a number's unit and a closed list's length; under the choice, the line the settings page draws for such
// a preference, live, with the control prefs_page.control_of gives (src/md/features/everything-palette.md). Each
// combination is a preference of a registry of its own, registered the first time it is shown, with demo values.
//   build/showcase --scene=values --value=size            a value kind (config.VALUE_KIND_NAMES), or list3, list12
//   build/showcase --scene=values --value=duration --unit=s --open   its unit by its symbol; its control opened

import "core:fmt"
import "core:math"
import "core:strings"
import config "gt:config"
import lucide "gt:lucide"
import prefs_page "gt:prefs_page"
import "gt:ui"

// The closed lists: none, three choices (a row of buttons), twelve (a list).
Values_List :: enum u8 { None, Three, Twelve }

Values :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	storage: config.Kind,
	kind:    config.Value_Kind,
	unit:    int,           // of config.KIND_UNITS[kind]
	list:    Values_List,
	names:   [dynamic]string,   // the preferences registered (owned: the registry keeps the Defs' names)
	open:    bool,          // the control opened at the first build (--open)
}

@(private = "file", rodata) STORAGES := [?]config.Kind{.Bool, .Int, .Float, .String}
@(private = "file", rodata) STORAGE_WORDS := [?]string{"Bool", "Int", "Float", "String"}
@(private = "file", rodata) LIST_WORDS := [len(Values_List)]string{"Free", "3 choices", "12 choices"}   // (Values_List's order)
@(private = "file", rodata) SIZES := [?]string{"small", "medium", "large"}
@(private = "file", rodata) MONTHS := [?]string{"january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"}

// What each kind is, as the scene says it.
@(private = "file", rodata)
KIND_WORDS := [config.Value_Kind]string{
	.Plain = "Plain", .Font_Family = "Font family", .Theme = "Theme", .Color = "Colour", .Path = "Path",
	.Address = "Address", .Keys = "Keys", .Size = "Size", .Duration = "Duration", .Fraction = "Fraction",
	.Length = "Length", .Factor = "Factor", .Rate = "Rate",
}

@(private = "file", rodata)
CONTROL_WORDS := [prefs_page.Control]string{
	.Custom = "the program's own", .Switch = "a switch", .Segments = "a row of buttons", .List = "a list",
	.Font_Family = "the font picker, each family in its face", .Theme = "the themes as cards", .Color = "the colour picker",
	.Keys = "the shortcut recorder", .Number = "a slider and a field, with its unit", .Field = "a field",
}

// From the command line: `value` a kind's name or list3 / list12, `unit` a unit's symbol, `open` its control opened.
values_open :: proc(v: ^Values, value, unit: string, open: bool) {
	v.prefs = config.prefs_make()
	values_choose(v, value, unit, open)
}

// Shows the value named `value` (a kind's name, list3, list12; "": a font family), in its first storage, its unit of
// symbol `unit` ("": the kind's first); `open`: its control opened at the next build.
values_choose :: proc(v: ^Values, value, unit: string, open: bool) {
	v.storage, v.kind, v.unit, v.list = .String, .Font_Family, 0, .None
	switch value {
	case "":
	case "list3":  v.kind, v.list = .Plain, .Three
	case "list12": v.kind, v.list = .Plain, .Twelve
	case:
		if k, ok := config.value_kind_of(value); ok {
			v.kind = k
			for s in STORAGES { if config.value_kind_stores(k, s) { v.storage = s; break } }
		}
	}
	for u, i in config.KIND_UNITS[v.kind] { if config.UNITS[u].symbol == unit { v.unit = i } }
	v.open = open
}

values_close :: proc(v: ^Values) {
	prefs_page.destroy(&v.page)
	config.prefs_destroy(&v.prefs)
	for n in v.names { delete(n) }
	delete(v.names)
}

values_build :: proc(app: ^App, em: f32) {
	v := &app.values
	heading("Values", "A setting says what its value is: a family, a theme, a colour, a size, a time. The control comes from that, in one table: no program draws one for a name. Choose a value; the settings page's line for it is under the choice.", em)
	if ui.card("The value", lucide.SLIDERS_HORIZONTAL) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, gap = ui.Vec2{0, math.round(em * ui.SPACE_2)}})
		if ui.column(id = "###choices") { values_choice(v) }
	}
	ui.space(ui.ITEM_GAP)
	name := values_name(v)
	values_register(v, name)
	e := config.entry(&v.prefs, config.ref_of(&v.prefs, name))
	o := values_options(app)
	c := prefs_page.control_of(e.def, values_choices(e.def), len(o.themes), false)
	if v.open {
		v.open = false
		prefs_page.control_open(&v.page, name)
	}
	if ui.card(fmt.tprintf("Its control: %s", CONTROL_WORDS[c]), lucide.SETTINGS_2) {
		prefs_page.setting_line(&v.page, &v.prefs, o, name)
		// (a number's file text is not what the line shows: "4194304" for 4 MiB, "0.64" for 64 %; a text's is)
		if e.def.kind == .Int || e.def.kind == .Float {
			if ui.tags("weak") {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("In the settings file: %s###stored", config.value_string(&v.prefs, config.ref_of(&v.prefs, name))))
			}
		}
	}
}

// The choice: the storage, the kinds it keeps, a measure's unit, a text's closed list.
@(private = "file")
values_choice :: proc(v: ^Values) {
	if room, ok := choice_row("Stored as"); ok {
		at := 0
		for s, i in STORAGES { if s == v.storage { at = i } }
		if choose("###storage", STORAGE_WORDS[:], &at, room) {
			v.storage = STORAGES[at]
			if !config.value_kind_stores(v.kind, v.storage) { v.kind, v.unit = .Plain, 0 }
			if v.storage != .String { v.list = .None }
		}
	}
	if v.storage == .Bool { return }
	kinds := make([dynamic]config.Value_Kind, context.temp_allocator)
	words := make([dynamic]string, context.temp_allocator)
	at := 0
	for k in config.Value_Kind {
		if !config.value_kind_stores(k, v.storage) { continue }
		if k == v.kind { at = len(kinds) }
		append(&kinds, k)
		append(&words, KIND_WORDS[k])
	}
	if room, ok := choice_row("Value kind"); ok {
		if choose("###kind", words[:], &at, room) { v.kind, v.unit, v.list = kinds[at], 0, .None }
	}
	if units := config.KIND_UNITS[v.kind]; len(units) > 1 {
		symbols := make([]string, len(units), context.temp_allocator)
		for u, i in units { symbols[i] = config.UNITS[u].symbol }
		if room, ok := choice_row("Unit"); ok { choose("###unit", symbols, &v.unit, room) }
	}
	if v.storage == .String && v.kind == .Plain {
		list := int(v.list)
		if room, ok := choice_row("Closed list"); ok {
			if choose("###list", LIST_WORDS[:], &list, room) { v.list = Values_List(list) }
		}
	}
}

// `if room, ok := choice_row("Unit"); ok { choose(..., room) }`: a choice laid out as the settings page's line under it,
// so the two cards align: its name at the left, its control at the right edge, as wide as it is. `room`: the width its
// control had in the last layout (0: not laid out yet).
@(private = "file", require_results, deferred_none = ui.pop_parent)
choice_row :: proc(name: string) -> (room: f32, ok: bool) {
	em := ui.font_size()
	gap := math.round(em * ui.ITEM_GAP)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center, gap = ui.Vec2{gap, 0}})
	row := ui.build_box({}, fmt.tprintf("###choice_%s", name))
	ui.push_parent(row)
	words: f32
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.5)), text_pad = 0})
		// (a name is never cut: its words on one line are its least, the row goes on growing past them)
		b := ui.label(fmt.tprintf("%s###name", name)).box
		words = math.ceil(b.text_dim.x)
		b.pref[.X].least = words
	}
	if w := row.rect.max.x - row.rect.min.x; w > 0 { room = w - words - gap }
	ui.next({height = ui.px(ui.control_height())})
	return room, true
}

// One of `words`: a segmented control when the room its row had holds it, a list to choose from when not (seven kinds of
// value in a narrow window).
@(private = "file")
choose :: proc(id: string, words: []string, at: ^int, room: f32) -> bool {
	if room == 0 || ui.segmented_width(words) <= room { return ui.segmented(id, words, at) }
	return ui.dropdown(id, words, at)
}

// The preference of the combination chosen (a test finds its line by it: "set_" and this name).
values_name :: proc(v: ^Values) -> string {
	unit := config.Unit.None
	if us := config.KIND_UNITS[v.kind]; len(us) > 0 { unit = us[clamp(v.unit, 0, len(us) - 1)] }
	return fmt.tprintf("values.%v.%s.%v.%v", v.storage, config.VALUE_KIND_NAMES[v.kind], unit, v.list)
}

@(private = "file")
values_choices :: proc(d: config.Def) -> int { return len(d.choices) }

// Registers the combination's preference at its first showing, with a demo value of its kind.
@(private = "file")
values_register :: proc(v: ^Values, name: string) {
	if config.ref_of(&v.prefs, name) != config.NO_REF { return }
	kept := strings.clone(name)
	append(&v.names, kept)
	us := config.KIND_UNITS[v.kind]
	unit := len(us) > 0 ? us[clamp(v.unit, 0, len(us) - 1)] : config.Unit.None
	// (a setting a program could have, with its own title and what it does: the choice card above already says the
	// storage and the kind, the line does not say them again)
	d := config.Def{name = kept, kind = v.storage, value_kind = v.kind, unit = unit}
	number :: proc(d: ^config.Def, value, lo, hi: f64) {
		if d.kind == .Int { d.default.i = i64(value) } else { d.default.f = value }
		d.bounded, d.min, d.max = hi > lo, lo, hi
	}
	switch v.kind {
	case .Plain:
		switch v.storage {
		case .Bool:
			d.title, d.description, d.default.b = "Spell check", "Underline the words the dictionary does not know.", true
		case .Int:
			d.title, d.description = "Recent files", "How many the File menu lists."
			number(&d, 12, 0, 50)
		case .Float:
			d.title, d.description = "Text gamma", "How the edges of text are weighted: higher draws it thinner."
			number(&d, 1.8, 1, 3)
		case .String:
			switch v.list {
			case .None:   d.title, d.description, d.default.s = "File name", "The name a new picture is saved under.", "harbour-at-dusk"
			case .Three:  d.title, d.description, d.default.s, d.choices = "Icon size", "The icons of the tool bar.", "medium", SIZES[:]
			case .Twelve: d.title, d.description, d.default.s, d.choices = "Year starts in", "The first month of a financial year.", "march", MONTHS[:]
			}
		}
	case .Font_Family: d.title, d.description = "Editor font", "The family of the editor's text."
	case .Theme:       d.title, d.description, d.default.s = "Editor theme", "The colours of the editor, apart from the window's.", "Graphite"
	case .Color:       d.title, d.description, d.default.s = "Accent colour", "The colour of the selection and of links.", "#e8743b"
	case .Path:        d.title, d.description, d.default.s = "Pictures folder", "Where a screenshot is saved.", "~/Pictures"
	case .Address:     d.title, d.description, d.default.s = "Update server", "Where new versions are found.", "https://example.org/updates/"
	case .Keys:        d.title, d.description, d.default.s = "Show the window", "Brings the window forward from any program.", "Ctrl+Shift+K"
	case .Size:
		#partial switch unit {
		case .Kibibyte: d.title, d.description = "Largest answer kept", "A longer answer is not kept for the inspector."; number(&d, 4096, 0, 0)
		case .Mebibyte: d.title, d.description = "Memory for pages", "Pages kept to go back past this are dropped."; number(&d, 256, 0, 0)
		case:           d.title, d.description = "Cache size", "Pictures past this are dropped, the oldest first."; number(&d, 4 << 20, 0, 0)
		}
	case .Duration:
		#partial switch unit {
		case .Second: d.title, d.description = "Message time", "How long a message stays."; number(&d, d.kind == .Int ? 2 : 1.5, 0, 10)
		case .Minute: d.title, d.description = "Lock after", "The time without a key or a move before the screen locks."; number(&d, 5, 0, 60)
		case .Hour:   d.title, d.description = "Check for updates every", ""; number(&d, 24, 1, 168)
		case .Day:    d.title, d.description = "Keep the history for", "Older visits are forgotten."; number(&d, 90, 0, 365)
		case:         d.title, d.description = "Autosave delay", "How long after the last key the document is saved."; number(&d, 300, 0, 2000)
		}
	case .Fraction:    d.title, d.description, d.default.f = "Window opacity", "How solid the window is: at 100 %, nothing behind it shows.", 0.64
	case .Length:
		#partial switch unit {
		case .Em:       d.title, d.description = "Paragraph gap", "The room between two paragraphs."; number(&d, d.kind == .Int ? 2 : 1.5, 0, 4)
		case .Milli_Em: d.title, d.description = "Outline tolerance", "How far a drawn curve may stray from the font's."; number(&d, 2, 0, 20)
		case:           d.title, d.description = "Text size", ""; number(&d, 14, 10, 24)
		}
	case .Factor:      d.title, d.description = "Zoom", "How large the page is drawn."; number(&d, 1.25, 0.5, 2)
	case .Rate:
		if unit == .Pixel_Per_Second {
			d.title, d.description = "Scroll speed", "How fast the middle button scrolls at the most."; number(&d, 400, 0, 5000)
		} else {
			d.title, d.description = "Key repeat rate", "The characters a second while a key is held."; number(&d, 30, 1, 100)
		}
	}
	config.register(&v.prefs, []config.Def{d})
}

@(private = "file")
values_options :: proc(app: ^App) -> prefs_page.Page_Options {
	return {user = app, themes = app.themes_file.all[:], themes_light = app.shown.light}
}
