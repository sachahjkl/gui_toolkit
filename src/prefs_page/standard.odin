package tk_prefs_page

// The preferences every program of the toolkit has, declared once here: what changes the look, the text, the scrolling,
// the hand's feel, the timings, the rendering, the updates and the program on the desktop. Each is a setting of the
// toolkit with today's default; nothing is blocked: a technical one is `advanced` (shown, folded), never hidden. Their
// names are fixed: the programs' files hold them, and the page knows some of them (Options.themes shows
// appearance.theme as cards). docs/settings.md lists them all.
//
//	d := prefs_page.STANDARD_DEFAULTS
//	d.theme, d.app_name = "cliche", "cliche"
//	prefs_page.standard_register(&prefs, prefs_page.STANDARD_ALL, d)
//	config.register(&prefs, PREF_DEFS[:])   // the program's own
//	prefs_page.standard_watch(&app.standard, &prefs, &app.state, {renderer = &r, fonts = &fonts})   // applied now, and at each change
//	a := prefs_page.appearance_read(&prefs); defer prefs_page.appearance_free(&a)
//	ui.theme_show(&theme, themes, prefs_page.appearance_choice(a), &shown, space)

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import config "../config"
import "../font"
import "../render"
import shortcuts "../shortcuts"
import "../ui"

Standard_Set :: enum u8 {
	Appearance,   // appearance.*: theme, mode, finish, glow, text size, zoom, density, rounding, corners, animations; window.*
	Text,         // appearance.text.*: fonts, emoji, how text is drawn
	Scrolling,    // scrolling.*: the glide, the wheel, the bars, the middle button, the fling
	Input,        // input.*: repeats, undo, typeahead, steps, zoom step
	Timing,       // timing.*: tooltips, menus, the palette's fade
	Rendering,    // rendering.*: presentation, latency, partial redraw, filters (all advanced)
	Update,       // update.*: automatic updates, channel, address
	Session,      // general.*: in the menu, with the session, messages, language
}
Standard :: bit_set[Standard_Set]

STANDARD_ALL :: Standard{.Appearance, .Text, .Scrolling, .Input, .Timing, .Rendering, .Update, .Session}

// The defaults that are the program's, and its name for the descriptions. Start from STANDARD_DEFAULTS: a zero `menu`
// is off. The other standard preferences have the toolkit's defaults (ui.FEEL_DEFAULT, font.DEFAULT_SETTINGS...).
Standard_Defaults :: struct {
	theme:        string,   // a name of the program's themes (a literal: the registry keeps it)
	mode:         string,   // "system", "dark" or "light" ("": "system")
	finish:       string,   // a name of ui.FINISH_NAMES ("": "machined")
	font_size:    f32,      // in logical pixels (0: 14)
	glow:         f32,      // the machined finish's halos, 0 to 1
	system_title: bool,     // the system draws the title bar (false: the program's own, integrated)
	menu:         bool,     // in the application menu
	autostart:    bool,     // started with the session
	update_auto:  bool,     // updates come by themselves
	update_channel:  string,   // the channel updates come from ("": a product without channels; a literal)
	update_base_url: string,   // where they come from (a literal)
	app_name:     string,   // "Start <app_name> with the session"
	// any other standard setting's default, as the program wants it (its rounding, its partial redraw...): a name and its
	// value as the settings file writes it. A reset then comes back to the program's look. (Literals: the registry keeps them.)
	values:       []Standard_Value,
}

Standard_Value :: struct { name, value: string }

// The defaults a program changes only where it differs: its theme and its name.
STANDARD_DEFAULTS :: Standard_Defaults{mode = "system", finish = "machined", font_size = 14, glow = 1, menu = true, update_auto = true}

THEME_PREF     :: "appearance.theme"
MODE_PREF      :: "appearance.mode"
FINISH_PREF    :: "appearance.finish"
FONT_SIZE_PREF :: "appearance.font_size"
GLOW_PREF      :: "appearance.glow"
MENU_PREF      :: "general.menu"
AUTOSTART_PREF :: "general.autostart"
MESSAGES_PREF  :: "general.messages"
LANGUAGE_PREF  :: "general.language"
SYSTEM_TITLE_PREF :: "window.system_title"
UPDATE_AUTO_PREF  :: "update.auto"
UI_FONT_PREF    :: "appearance.text.ui_font"
MONO_FONT_PREF  :: "appearance.text.mono_font"
PROSE_FONT_PREF :: "appearance.text.prose_font"
EMOJI_FONT_PREF :: "appearance.text.emoji_font"

FONT_SIZE_MIN :: 10
FONT_SIZE_MAX :: 24

// (static: the registry keeps the slices of a Def)
@(private = "file", rodata) FINISH_CHOICES := [?]string{"machined", "edged", "flat", "gradient", "glass"}   // the ones a program means first
@(private = "file", rodata) MODE_CHOICES := [?]string{"system", "dark", "light"}
@(private = "file", rodata) ANIMATION_CHOICES := [?]string{"system", "on", "off"}
@(private = "file", rodata) SMOOTH_CHOICES := [?]string{"follow", "on", "off"}
@(private = "file", rodata) CURVE_CHOICES := [?]string{"impulse", "ease_out", "exponential"}
@(private = "file", rodata) TOAST_CHOICES := [?]string{"top_left", "top_center", "top_right", "middle_left", "middle_right", "bottom_left", "bottom_center", "bottom_right"}
@(private = "file", rodata) SUBPIXEL_CHOICES := [?]string{"off", "rgb", "bgr"}
@(private = "file", rodata) GRID_FIT_CHOICES := [?]string{"default", "enabled", "disabled"}
@(private = "file", rodata) RENDERER_CHOICES := [?]string{"atlas", "slug"}
@(private = "file", rodata) RENDERING_CHOICES := [?]string{"natural_symmetric", "natural", "gdi_classic", "aliased"}
@(private = "file", rodata) TEXT_CURVE_CHOICES := [?]string{"none", "srgb", "power"}
@(private = "file", rodata) BLEND_CHOICES := [?]string{"linear", "srgb"}
@(private = "file", rodata) PRESENT_CHOICES := [?]string{"vsync", "tearing"}
@(private = "file", rodata) FILTER_CHOICES := [?]string{"half", "unorm8"}
@(private = "file", rodata) MESSAGES_CHOICES := [?]string{"system", "window", "off"}

@(private = "file", rodata) MENU_TAGS := [?]string{"launcher", "desktop file", "start menu", "icon"}
@(private = "file", rodata) AUTOSTART_TAGS := [?]string{"login", "startup", "boot", "session"}
@(private = "file", rodata) MESSAGES_TAGS := [?]string{"notifications", "toasts", "messages", "feedback", "copied", "saved"}
@(private = "file", rodata) THEME_TAGS := [?]string{"colours", "colors", "palette", "dark", "light", "look"}
@(private = "file", rodata) ROUNDING_TAGS := [?]string{"corners", "round", "square", "radius"}
@(private = "file", rodata) MODE_TAGS := [?]string{"dark", "light", "night", "day"}
@(private = "file", rodata) FINISH_TAGS := [?]string{"style", "look", "bevel", "flat"}
@(private = "file", rodata) FONT_SIZE_TAGS := [?]string{"text size", "zoom", "bigger", "smaller"}
@(private = "file", rodata) ZOOM_TAGS := [?]string{"scale", "bigger", "smaller", "size"}
@(private = "file", rodata) DENSITY_TAGS := [?]string{"compact", "spacing", "rows"}
@(private = "file", rodata) MOTION_TAGS := [?]string{"motion", "transitions", "reduce motion"}
@(private = "file", rodata) FONT_TAGS := [?]string{"typeface", "family", "font"}
@(private = "file", rodata) TEXT_LOOK_TAGS := [?]string{"antialiasing", "cleartype", "smoothing", "sharpness", "weight"}
@(private = "file", rodata) SCROLL_TAGS := [?]string{"wheel", "glide", "smooth"}
@(private = "file", rodata) AUTOSCROLL_TAGS := [?]string{"middle click", "wheel click", "autoscroll"}
@(private = "file", rodata) REPEAT_TAGS := [?]string{"keyboard", "repeat", "held"}
@(private = "file", rodata) UPDATE_TAGS := [?]string{"upgrade", "version", "release"}
@(private = "file", rodata) VSYNC_TAGS := [?]string{"vsync", "tearing", "latency", "fps"}
@(private = "file", rodata) LANGUAGE_TAGS := [?]string{"locale", "translation", "language"}

// The order of the standard groups among a program's own (theirs are 0): the session and the look first, the technical
// ones last.
@(private = "file") ORDER_GENERAL    :: -110
@(private = "file") ORDER_APPEARANCE :: -100
@(private = "file") ORDER_WINDOW     :: -99
@(private = "file") ORDER_SCROLLING  :: 100
@(private = "file") ORDER_INPUT      :: 101
@(private = "file") ORDER_TIMING     :: 102
@(private = "file") ORDER_UPDATE     :: 103
@(private = "file") ORDER_RENDERING  :: 104

// The Slug tolerance's unit: a thousandth of an em (its real values are 1/65536 to 1/64 em).
@(private = "file") SLUG_TOLERANCE_UNIT :: 1000.0

// Registers the standard preferences of `sets`, in the page's order (before the program's own: the page lists a group's
// preferences in the order they came), and the titles of their groups (a program that registers a title after gives its
// own words). The descriptions that name `defaults.app_name` are made in `allocator` and must live as long as `prefs`
// (the registry keeps them, and frees no description): a program's registry lives as long as the program; a test gives
// an arena or the temporary allocator.
standard_register :: proc(prefs: ^config.Prefs, sets: Standard, defaults: Standard_Defaults, allocator := context.allocator) {
	d := defaults
	if d.mode == "" { d.mode = "system" }
	if d.finish == "" { d.finish = "machined" }
	if d.font_size <= 0 { d.font_size = 14 }
	name := d.app_name != "" ? d.app_name : "the program"
	a := allocator
	defs := make([dynamic]config.Def, context.temp_allocator)
	feel := ui.FEEL_DEFAULT
	fs := font.DEFAULT_SETTINGS
	tr := render.TEXT_RENDERING_LINEAR
	if .Session in sets {
		config.title_register(prefs, "general", "General", ORDER_GENERAL)
		append(&defs, config.Def{
			name = MENU_PREF, title = "In the application menu", kind = .Bool, default = {b = d.menu},
			description = fmt.aprintf("Put %s in the %s, with its icon. The desktop then knows %s by its name: its shortcuts and its windows' places come from that.", name, menu_words(), name, allocator = a),
			tags = MENU_TAGS[:],
		})
		append(&defs, config.Def{
			name = AUTOSTART_PREF, title = "Start with the session", kind = .Bool, default = {b = d.autostart},
			description = fmt.aprintf("Start %s with the session, so that its shortcuts work from the start.", name, allocator = a),
			tags = AUTOSTART_TAGS[:],
		})
		append(&defs, config.Def{
			name = MESSAGES_PREF, title = "Messages", kind = .String, default = {s = "system"},
			description = fmt.aprintf("Where %s says what it did (copied, saved, deleted). System: the system's notifications, or %s's window where the system has none. Window: only in %s's window. Off: nowhere; a failure is always said.", name, name, name, allocator = a),
			choices = MESSAGES_CHOICES[:], tags = MESSAGES_TAGS[:],
		})
		append(&defs, config.Def{
			name = LANGUAGE_PREF, title = "Language", kind = .String, default = {s = "system"}, restart = true,
			description = "The language of the interface, as a language tag (\"fr\", \"en-GB\"). System: the system's.",
			tags = LANGUAGE_TAGS[:],
		})
	}
	if .Appearance in sets {
		config.title_register(prefs, "appearance", "Appearance", ORDER_APPEARANCE)
		append(&defs, config.Def{
			name = THEME_PREF, title = "Theme", kind = .String, default = {s = d.theme},
			description = fmt.aprintf("The colours of %s's windows.", name, allocator = a),
			tags = THEME_TAGS[:],
		})
		append(&defs, config.Def{
			name = MODE_PREF, title = "Light or dark", kind = .String, default = {s = d.mode},
			description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.",
			choices = MODE_CHOICES[:], tags = MODE_TAGS[:],
		})
		append(&defs, config.Def{
			name = FINISH_PREF, title = "Finish", kind = .String, default = {s = d.finish},
			description = "How surfaces are drawn. Machined: bevelled buttons, sunken fields, carved lines. Edged: the same reliefs, crisp, with square corners. Flat: plain surfaces and thin lines. Gradient: faces lit from the top. Glass: glossy faces.",
			choices = FINISH_CHOICES[:], tags = FINISH_TAGS[:],
		})
		append(&defs, config.Def{
			name = GLOW_PREF, title = "Glow", kind = .Float, default = {f = decimal(d.glow)}, bounded = true, min = 0, max = 1,
			description = "How much the buttons and fields of the machined finish glow. 0: no halo.",
		})
		append(&defs, config.Def{
			name = FONT_SIZE_PREF, title = "Text size", kind = .Float, default = {f = decimal(d.font_size)},
			description = "The size of the text, in logical pixels.", min = FONT_SIZE_MIN, max = FONT_SIZE_MAX, bounded = true, unit = "px",
			tags = FONT_SIZE_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.zoom", title = "Zoom", kind = .Float, default = {f = 1}, bounded = true, min = ui.ZOOM_MIN, max = ui.ZOOM_MAX, unit = "×",
			description = "How large the whole interface is drawn: text, rows and gaps. Ctrl+wheel, Ctrl+= and Ctrl+- change it for the run.",
			tags = ZOOM_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.density", title = "Density", kind = .Float, default = {f = 1}, bounded = true, min = ui.DENSITY_MIN, max = ui.DENSITY_MAX, unit = "×",
			description = "The height of rows and the vertical gaps; the text keeps its size. Lower is more compact.",
			tags = DENSITY_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.rounding", title = "Rounding", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 2, unit = "×",
			description = "How round the corners are. 0: square corners. The edged finish is always square.",
			tags = ROUNDING_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.corner_smoothing", title = "Smooth corners", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 1,
			description = "The shape of a rounded corner: 0, a circle's arc; 1, a squircle, whose curve starts gently.",
		})
		append(&defs, config.Def{
			name = "appearance.animations", title = "Animations", kind = .String, default = {s = "system"},
			description = "Whether transitions move: as the system asks (its setting to reduce motion), always, or never.",
			choices = ANIMATION_CHOICES[:], tags = MOTION_TAGS[:],
		})
		config.title_register(prefs, "window", "Window", ORDER_WINDOW)
		append(&defs, config.Def{
			name = SYSTEM_TITLE_PREF, title = "The system's title bar", kind = .Bool, default = {b = d.system_title},
			description = fmt.aprintf("The system draws the title bar of %s's windows. Off: %s draws its own, with its tabs and buttons in it.", name, name, allocator = a),
		})
		append(&defs, config.Def{
			name = "window.toast_position", title = "Where messages show", kind = .String, default = {s = "bottom_right"},
			description = "Where in the window its short messages show.",
			choices = TOAST_CHOICES[:], tags = MESSAGES_TAGS[:],
		})
	}
	if .Text in sets {
		config.title_register(prefs, "appearance.text", "Text and fonts")
		append(&defs, config.Def{
			name = UI_FONT_PREF, title = "Interface font", kind = .String, default = {s = ""}, restart = true,
			description = "The family of the interface's text, as the system names it (\"Inter\"). Empty: the program's.",
			tags = FONT_TAGS[:],
		})
		append(&defs, config.Def{
			name = MONO_FONT_PREF, title = "Monospace font", kind = .String, default = {s = ""}, restart = true,
			description = "The family of code and of what lines up in columns. Empty: the program's.",
			tags = FONT_TAGS[:],
		})
		append(&defs, config.Def{
			name = PROSE_FONT_PREF, title = "Reading font", kind = .String, default = {s = ""}, restart = true,
			description = "The family of long text to read (documents, messages). Empty: the program's.",
			tags = FONT_TAGS[:],
		})
		append(&defs, config.Def{
			name = EMOJI_FONT_PREF, title = "Emoji font", kind = .String, default = {s = ""}, restart = true,
			description = "A font file whose emoji are drawn in place of the program's. Empty: the program's.",
		})
		append(&defs, config.Def{
			name = "appearance.text.system_fallback", title = "The system's fonts as a last resort", kind = .Bool, default = {b = fs.system_fallback},
			description = "A character no font of the program has comes from a font of the system.",
		})
		append(&defs, config.Def{
			name = "appearance.text.color_emoji", title = "Emoji in colour", kind = .Bool, default = {b = fs.color_glyphs},
			description = "Emoji and other colour glyphs in their colours. Off: their outline, in the text's colour.",
		})
		append(&defs, config.Def{
			name = "appearance.text.subpixel", title = "Subpixel text", kind = .String, default = {s = SUBPIXEL_CHOICES[int(fs.subpixel_text)]},
			description = "Text smoothed per colour stripe of the screen's pixels, in their order (rgb or bgr): sharper at small sizes on a screen with stripes. Off: grey smoothing, right on every screen.",
			choices = SUBPIXEL_CHOICES[:], tags = TEXT_LOOK_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.text.gamma", title = "Gamma", kind = .Float, default = {f = decimal(tr.gamma)}, bounded = true, min = 0.25, max = 4,
			description = "The exponent of the power curve the text and its background are blended through (with the power curve). Higher is lighter text on a dark background.",
			tags = TEXT_LOOK_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.text.contrast", title = "Contrast", kind = .Float, default = {f = decimal(tr.contrast)}, bounded = true, min = 0, max = 1,
			description = "How much the edges of the letters are boosted against their background (with a curve). 0: none.",
			tags = TEXT_LOOK_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.text.coverage_exponent", title = "Weight", kind = .Float, default = {f = decimal(tr.coverage_exponent)}, bounded = true, min = 0.1, max = 4,
			description = "The exponent each pixel's coverage is raised to: below 1 thickens the text, above 1 thins it.",
			tags = TEXT_LOOK_TAGS[:],
		})
		append(&defs, config.Def{
			name = "appearance.text.curve", title = "Blending curve", kind = .String, default = {s = TEXT_CURVE_CHOICES[int(tr.curve)]}, advanced = true,
			description = "How a letter's colour meets its background. None: as the blending space does. Srgb: in linear light, as Chromium on Windows. Power: through the gamma above, as Chromium on Linux.",
			choices = TEXT_CURVE_CHOICES[:],
		})
		append(&defs, config.Def{
			name = "appearance.text.blend_space", title = "Blending space", kind = .String, default = {s = "linear"}, advanced = true,
			description = "Where colours are mixed: in linear light (correct mixing, what the toolkit is tuned for), or in sRGB values, as web browsers do.",
			choices = BLEND_CHOICES[:],
		})
		append(&defs, config.Def{
			name = "appearance.text.subpixel_steps", title = "Subpixel positions", kind = .Int, default = {i = i64(fs.subpixel_steps)}, bounded = true, min = 1, max = 4, advanced = true,
			description = "The positions of a letter within a pixel. 1: whole pixels, crisper and rougher spacing; 4: the most even spacing.",
		})
		append(&defs, config.Def{
			name = "appearance.text.grid_fit", title = "Grid fitting", kind = .String, default = {s = GRID_FIT_CHOICES[int(fs.grid_fit)]}, advanced = true,
			description = "Whether outlines are fitted to the pixel grid: crisper stems, shapes a little off. Default: as the font asks.",
			choices = GRID_FIT_CHOICES[:],
		})
		when ODIN_OS == .Windows {
			// (elsewhere there is no rasterizer of bitmaps: Slug draws every letter)
			append(&defs, config.Def{
				name = "appearance.text.renderer", title = "Text renderer", kind = .String, default = {s = RENDERER_CHOICES[int(fs.text_renderer)]}, advanced = true,
				description = "How letters reach the screen. Atlas: bitmaps the system draws, hinted per size. Slug: the outlines, drawn by the graphics card, sharp at any scale.",
				choices = RENDERER_CHOICES[:],
			})
			append(&defs, config.Def{
				name = "appearance.text.rendering", title = "DirectWrite mode", kind = .String, default = {s = RENDERING_CHOICES[int(fs.rendering)]}, advanced = true,
				description = "How DirectWrite draws the atlas's letters.",
				choices = RENDERING_CHOICES[:],
			})
		}
		append(&defs, config.Def{
			name = "appearance.text.slug_tolerance", title = "Slug tolerance", kind = .Float, default = {f = f64(fs.slug_tolerance) * SLUG_TOLERANCE_UNIT}, bounded = true,
			min = 1.0 / 65536 * SLUG_TOLERANCE_UNIT, max = 1.0 / 64 * SLUG_TOLERANCE_UNIT, unit = "‰ em", advanced = true,
			description = "The largest distance between a letter's curve and the simpler curves Slug draws in its place. Lower is truer and heavier.",
		})
		append(&defs, config.Def{
			name = "appearance.text.color_async", title = "Colour glyphs on a thread", kind = .Bool, default = {b = fs.color_async}, advanced = true,
			description = "Colour glyphs are drawn on a thread of their own: they show a moment later, and a frame never waits for them.",
		})
		append(&defs, config.Def{
			name = "appearance.text.atlas_pages", title = "Atlas pages", kind = .Int, default = {i = i64(fs.max_gray_pages)}, bounded = true, min = 1, max = 64, advanced = true,
			description = "The pages of letters kept before the least used one is drawn over.",
		})
		append(&defs, config.Def{
			name = "appearance.text.color_pages", title = "Colour atlas pages", kind = .Int, default = {i = i64(fs.max_color_pages)}, bounded = true, min = 1, max = 64, advanced = true,
			description = "The pages of colour glyphs kept before the least used one is drawn over.",
		})
		append(&defs, config.Def{
			name = "appearance.text.page_size", title = "Atlas page size", kind = .Int, default = {i = i64(fs.page_size)}, bounded = true, min = 256, max = 8192, unit = "px", advanced = true, restart = true,
			description = "The side of a page of the atlas.",
		})
		append(&defs, config.Def{
			name = "appearance.text.word_cache", title = "Words kept", kind = .Int, default = {i = i64(fs.word_cache)}, bounded = true, min = 0, max = 1 << 20, advanced = true,
			description = "The shaped words kept, so that a word measured again is not shaped again. 0: none.",
		})
		append(&defs, config.Def{
			name = "appearance.text.slug_pages", title = "Slug pages", kind = .Int, default = {i = i64(fs.slug_pages)}, bounded = true, min = 1, max = 2048, advanced = true,
			description = "The pages of outlines Slug keeps before the least used one is reused.",
		})
	}
	if .Scrolling in sets {
		sc := ui.DEFAULT_SCROLL
		au := ui.DEFAULT_AUTOSCROLL
		config.title_register(prefs, "scrolling", "Scrolling", ORDER_SCROLLING)
		config.title_register(prefs, "scrolling.autoscroll", "Middle-button scrolling")
		append(&defs, config.Def{
			name = "scrolling.smooth", title = "Smooth scrolling", kind = .String, default = {s = "follow"},
			description = "Whether a notch of the wheel glides or jumps. Follow: as the animations do.",
			choices = SMOOTH_CHOICES[:], tags = SCROLL_TAGS[:],
		})
		append(&defs, config.Def{
			name = "scrolling.duration", title = "Glide", kind = .Int, default = {i = i64(sc.duration_ms)}, bounded = true, min = 0, max = 1000, unit = "ms",
			description = "How long a glide lasts. 0: a jump.",
			tags = SCROLL_TAGS[:],
		})
		append(&defs, config.Def{
			name = "scrolling.wheel_lines", title = "Lines per notch", kind = .Float, default = {f = decimal(feel.wheel_lines)}, bounded = true, min = 1, max = 20,
			description = "The lines a notch of the wheel moves, where the system does not say.",
			tags = SCROLL_TAGS[:],
		})
		append(&defs, config.Def{
			name = "scrolling.autohide_scrollbars", title = "Hide the scroll bars", kind = .Bool, default = {b = false},
			description = "A scroll bar shows only while the pointer is over its view, or for a moment after it scrolled.",
		})
		append(&defs, config.Def{
			name = "scrolling.scrollbar_arrows", title = "Scroll bar arrows", kind = .Bool, default = {b = false},
			description = "An arrow button at each end of every scroll bar.",
		})
		append(&defs, config.Def{
			name = "scrolling.curve", title = "Glide curve", kind = .String, default = {s = CURVE_CHOICES[int(sc.curve)]}, advanced = true,
			description = "The shape of a glide. Impulse: a strong push then a long slowing, as Chromium. Ease out: a gentle slowing. Exponential: halves the distance each frame.",
			choices = CURVE_CHOICES[:],
		})
		append(&defs, config.Def{
			name = "scrolling.impulse", title = "Impulse", kind = .Float, default = {f = decimal(sc.impulse)}, bounded = true, min = 1, max = 20, advanced = true,
			description = "The strength of the impulse curve: higher starts faster and slows longer.",
		})
		append(&defs, config.Def{
			name = "scrolling.fling_stop_speed", title = "Fling stop speed", kind = .Float, default = {f = decimal(feel.fling_stop_speed)}, bounded = true, min = 0, max = 1000, unit = "px/s", advanced = true,
			description = "A fling of the finger ends under this speed.",
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.enabled", title = "Scroll with the middle button", kind = .Bool, default = {b = true},
			description = "A press of the wheel on a view drops an anchor; moving the pointer away scrolls, the farther the faster.",
			tags = AUTOSCROLL_TAGS[:],
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.toggle", title = "A click latches it", kind = .Bool, default = {b = au.toggle},
			description = "A short click of the wheel keeps the mode on until the next click; a press held ends it at its release.",
			tags = AUTOSCROLL_TAGS[:],
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.dead_zone", title = "Dead zone", kind = .Float, default = {f = decimal(au.dead_zone)}, bounded = true, min = 0, max = 100, unit = "px", advanced = true,
			description = "No scrolling while the pointer is this close to the anchor.",
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.max_speed", title = "Top speed", kind = .Float, default = {f = decimal(au.max_speed)}, bounded = true, min = 100, max = 50000, unit = "px/s", advanced = true,
			description = "The fastest it scrolls.",
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.full_dist", title = "Distance to top speed", kind = .Float, default = {f = decimal(au.full_dist)}, bounded = true, min = 10, max = 2000, unit = "px", advanced = true,
			description = "How far past the dead zone the top speed is reached.",
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.doubling", title = "Doubling distance", kind = .Float, default = {f = decimal(au.doubling)}, bounded = true, min = 1, max = 500, unit = "px", advanced = true,
			description = "The speed doubles for each this many pixels past the dead zone.",
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.tap", title = "Click", kind = .Int, default = {i = i64(au.tap_ms)}, bounded = true, min = 0, max = 2000, unit = "ms", advanced = true,
			description = "A press shorter than this, that hardly moved, is a click: it latches the mode.",
		})
		append(&defs, config.Def{
			name = "scrolling.autoscroll.tap_slop", title = "Click movement", kind = .Float, default = {f = decimal(au.tap_slop)}, bounded = true, min = 0, max = 50, unit = "px", advanced = true,
			description = "A press that moved more than this is a drag, never a click.",
		})
	}
	if .Input in sets {
		config.title_register(prefs, "input", "Input", ORDER_INPUT)
		append(&defs, config.Def{
			name = "input.key_repeat_delay", title = "Key repeat delay", kind = .Int, default = {i = i64(feel.key_repeat_delay_ms)}, bounded = true, min = 0, max = 2000, unit = "ms",
			description = "A held key repeats after this long, where the system does not say (Wayland, until the compositor does).",
			tags = REPEAT_TAGS[:],
		})
		append(&defs, config.Def{
			name = "input.key_repeat_rate", title = "Key repeat rate", kind = .Int, default = {i = i64(feel.key_repeat_rate)}, bounded = true, min = 0, max = 100, unit = "/s",
			description = "Then this many times a second, likewise. 0: no repeat.",
			tags = REPEAT_TAGS[:],
		})
		append(&defs, config.Def{
			name = "input.button_repeat_delay", title = "Button repeat delay", kind = .Int, default = {i = i64(feel.repeat_delay_ms)}, bounded = true, min = 0, max = 2000, unit = "ms",
			description = "A held button (a number's − and +, a scroll bar's arrow) repeats after this long.",
			tags = REPEAT_TAGS[:],
		})
		append(&defs, config.Def{
			name = "input.button_repeat_interval", title = "Button repeat interval", kind = .Int, default = {i = i64(feel.repeat_interval_ms)}, bounded = true, min = 1, max = 1000, unit = "ms",
			description = "Then once every this much.",
			tags = REPEAT_TAGS[:],
		})
		append(&defs, config.Def{
			name = "input.undo_steps", title = "Undo steps", kind = .Int, default = {i = i64(feel.undo_steps)}, bounded = true, min = 1, max = 10000,
			description = "The edits a text field remembers to undo.",
		})
		append(&defs, config.Def{
			name = "input.undo_merge", title = "Undo merge", kind = .Int, default = {i = i64(feel.undo_merge_ms)}, bounded = true, min = 0, max = 10000, unit = "ms",
			description = "Typing within this much of the previous edit is the same undo step. 0: each edit is a step.",
		})
		append(&defs, config.Def{
			name = "input.typeahead", title = "Type to find", kind = .Int, default = {i = i64(feel.typeahead_ms)}, bounded = true, min = 0, max = 5000, unit = "ms",
			description = "Keys typed in a list within this much of each other add up to one word, which the list goes to.",
		})
		append(&defs, config.Def{
			name = "input.zoom_step", title = "Zoom step", kind = .Float, default = {f = decimal(feel.zoom_step)}, bounded = true, min = 1.01, max = 2, unit = "×",
			description = "Ctrl+wheel, Ctrl+= and Ctrl+- multiply or divide the zoom by this.",
		})
		append(&defs, config.Def{
			name = "input.step_shift", title = "Shift step", kind = .Float, default = {f = feel.step_shift}, bounded = true, min = 1, max = 1000, unit = "×", advanced = true,
			description = "Shift multiplies the step of a slider or a number (a key, a notch of the wheel, a button).",
		})
		append(&defs, config.Def{
			name = "input.step_ctrl", title = "Ctrl step", kind = .Float, default = {f = feel.step_ctrl}, bounded = true, min = 1, max = 10000, unit = "×", advanced = true,
			description = "Ctrl multiplies the step of a number in text.",
		})
		append(&defs, config.Def{
			name = "input.step_alt", title = "Alt step", kind = .Float, default = {f = feel.step_alt}, bounded = true, min = 0.001, max = 1, unit = "×", advanced = true,
			description = "Alt multiplies the step of a number in text.",
		})
		append(&defs, config.Def{
			name = "input.step_page", title = "Page step", kind = .Float, default = {f = feel.step_page}, bounded = true, min = 1, max = 100, advanced = true,
			description = "Page Up and Page Down move a slider, or a number in text, this many steps.",
		})
	}
	if .Timing in sets {
		config.title_register(prefs, "timing", "Delays and menus", ORDER_TIMING)
		append(&defs, config.Def{
			name = "timing.tooltip_delay", title = "Tooltip delay", kind = .Int, default = {i = i64(feel.tooltip_delay_ms)}, bounded = true, min = 0, max = 5000, unit = "ms",
			description = "The pointer rests this long on something before its tooltip shows.",
		})
		append(&defs, config.Def{
			name = "timing.menu_hover", title = "Submenu delay", kind = .Int, default = {i = i64(feel.menu_hover_ms)}, bounded = true, min = 0, max = 2000, unit = "ms",
			description = "The pointer rests this long on a submenu's item before it opens, or before another closes.",
		})
		append(&defs, config.Def{
			name = "timing.menu_item_height", title = "Menu item height", kind = .Float, default = {f = decimal(feel.menu_item_em)}, bounded = true, min = 1.2, max = 4, unit = "em",
			description = "The height of a menu's item, times the density.",
		})
		append(&defs, config.Def{
			name = "timing.palette_fade", title = "Colour fade", kind = .Int, default = {i = i64(feel.palette_fade_ms)}, bounded = true, min = 0, max = 2000, unit = "ms",
			description = "A change of theme fades every colour for this long.",
		})
	}
	if .Update in sets {
		config.title_register(prefs, "update", "Updates", ORDER_UPDATE)
		append(&defs, config.Def{
			name = UPDATE_AUTO_PREF, title = "Update by itself", kind = .Bool, default = {b = d.update_auto},
			description = fmt.aprintf("Look for a new version of %s now and then, and install it: it takes effect at the next start.", name, allocator = a),
			tags = UPDATE_TAGS[:],
		})
		append(&defs, config.Def{
			name = "update.channel", title = "Channel", kind = .String, default = {s = d.update_channel}, restart = true,
			description = "The channel the updates come from (stable, beta...). Empty: the only one.",
			tags = UPDATE_TAGS[:],
		})
		append(&defs, config.Def{
			name = "update.base_url", title = "Address", kind = .String, default = {s = d.update_base_url}, restart = true, advanced = true,
			description = "Where the updates are published (a folder of the web).",
			tags = UPDATE_TAGS[:],
		})
	}
	if .Rendering in sets {
		config.title_register(prefs, "rendering", "Rendering", ORDER_RENDERING)
		append(&defs, config.Def{
			name = "rendering.present", title = "Presentation", kind = .String, default = {s = "vsync"}, advanced = true,
			description = "Vsync: each picture waits for the screen's refresh, whole. Tearing: it is shown at once, a picture may be cut where the screen was.",
			choices = PRESENT_CHOICES[:], tags = VSYNC_TAGS[:],
		})
		append(&defs, config.Def{
			name = "rendering.max_frame_latency", title = "Frames queued", kind = .Int, default = {i = 1}, bounded = true, min = 1, max = 3, advanced = true,
			description = "The pictures that may wait for the screen. 1: the least delay from a key to the screen; more: steadier under load.",
			tags = VSYNC_TAGS[:],
		})
		append(&defs, config.Def{
			name = "rendering.partial_redraw", title = "Partial redraw", kind = .Bool, default = {b = false}, advanced = true,
			description = "Each picture redraws only what changed in the interface.",
		})
		append(&defs, config.Def{
			name = "rendering.blur_sigma_limit", title = "Blur limit", kind = .Float, default = {f = render.DEFAULT_BLUR_SIGMA_LIMIT}, bounded = true, min = 2, max = render.MAX_BLUR_SIGMA, unit = "px", advanced = true,
			description = "A blur wider than this is computed on a smaller picture: faster, softer.",
		})
		append(&defs, config.Def{
			name = "rendering.filter_precision", title = "Filter precision", kind = .String, default = {s = "half"}, advanced = true,
			description = "The pictures of filters (blurs, shadows) in 16-bit floats (half), or in 8 bits (unorm8): half the memory, a little banding.",
			choices = FILTER_CHOICES[:],
		})
	}
	// (the theme's default must outlive the registry, as every Def's: the program's literal)
	// (the program's own defaults over the toolkit's, before the registry reads them)
	for v in d.values {
		for &def in defs {
			if def.name != v.name { continue }
			switch def.kind {
			case .Bool:   def.default.b = v.value == "true" || v.value == "1"
			case .Int:    if n, ok := strconv.parse_i64(v.value); ok { def.default.i = n }
			case .Float:  if f, ok := strconv.parse_f64(v.value); ok { def.default.f = f }
			case .String: def.default.s = v.value
			}
		}
	}
	config.register(prefs, defs[:])
}

// An f32 default as the decimal it was written as (f32 1.1 is 1.100000023841858 as an f64; the file and the reset
// rule read 1.1).
@(private = "file")
decimal :: proc(v: f32) -> f64 {
	d, _ := strconv.parse_f64(fmt.tprintf("%v", v))
	return d
}

// The launcher's place in the user's words (gt:desktop's menu_name says the same; the page does not import it).
@(private = "file")
menu_words :: proc() -> string {
	when ODIN_OS == .Windows { return "Start menu" } else { return "application menu" }
}

// Where the program's messages go (ui.Announcer.mode): general.messages, System when it is not registered.
messages_mode :: proc(prefs: ^config.Prefs) -> ui.Announce_Mode {
	r := config.ref_of(prefs, MESSAGES_PREF)
	if r == config.NO_REF { return .System }
	return ui.announce_mode_of(config.get_string(prefs, r))
}

// The look, as a program applies it.
Appearance :: struct {
	theme:     string,   // owned (appearance_free)
	mode:      ui.Theme_Mode,
	finish:    ui.Finish,
	font_size: f32,
	glow:      f32,
}

// The look the registry holds now. A preference that is not registered reads as its standard default.
appearance_read :: proc(prefs: ^config.Prefs, allocator := context.allocator) -> (a: Appearance) {
	a.mode = .System
	a.finish = .Machined
	a.font_size = 14
	a.glow = 1
	if r := config.ref_of(prefs, THEME_PREF); r != config.NO_REF { a.theme = strings.clone(config.get_string(prefs, r), allocator) }
	if r := config.ref_of(prefs, MODE_PREF); r != config.NO_REF { a.mode = ui.theme_mode_of(config.get_string(prefs, r)) }
	if r := config.ref_of(prefs, FINISH_PREF); r != config.NO_REF { a.finish = ui.finish_of(config.get_string(prefs, r)) }
	if r := config.ref_of(prefs, FONT_SIZE_PREF); r != config.NO_REF { a.font_size = f32(config.get_float(prefs, r)) }
	if r := config.ref_of(prefs, GLOW_PREF); r != config.NO_REF { a.glow = f32(config.get_float(prefs, r)) }
	return
}

appearance_free :: proc(a: ^Appearance, allocator := context.allocator) {
	delete(a.theme, allocator)
	a^ = {}
}

// What ui.theme_show takes for the look.
appearance_choice :: proc(a: Appearance) -> ui.Theme_Choice {
	return {name = a.theme, mode = a.mode, finish = a.finish, glow = a.glow}
}

// Whether the user's value of `name` is not its default: the page shows its reset button then, and Restore defaults
// while one of the page's is. A value the command line or a policy decides is not the user's. `keys`: the value is a
// key combination, compared as keys ("ctrl+print" is "Ctrl+Print").
differs_from_default :: proc(prefs: ^config.Prefs, name: string, keys := false) -> bool {
	r := config.ref_of(prefs, name)
	if r == config.NO_REF { return false }
	e := config.entry(prefs, r)
	if e.source != .User { return false }
	value, default := config.value_string(prefs, r), config.default_string(prefs, r)
	if keys { return !shortcuts.same_keys(value, default) }
	return value != default
}

////////////////////////////////
// Applying them

// What standard_apply reaches besides the interface (each nil: what it sets is left alone). The renderer: the corners,
// how text is blended, the presentation and the filters; the fonts: font.Settings; partial_redraw: a host's flag
// (host.Host.partial_redraw, which the host gives the interface at each frame; nil: ui.set_partial_redraw).
Standard_Targets :: struct {
	renderer:       ^render.Renderer,
	fonts:          ^font.State,
	partial_redraw: ^bool,
}

// Applies every standard preference that is registered and not at its default (the user's, the command line's, a
// policy's: where nobody said anything, what the program set stays) to the toolkit's setters (ui.set_feel, set_zoom, set_density,
// set_rounding, set_animations, set_smooth_scroll, the scroll and autoscroll settings, set_toast_position; the renderer's
// and the fonts' when `t` gives them). What is not registered is left as it is. The theme (appearance.theme, mode,
// finish, glow, font_size) stays the program's to show (appearance_read, ui.theme_show), as do the fonts by name, the
// title bar, the updates and the session (read at the start: Def.restart, or by the program's Updater and desktop.apply).
standard_apply :: proc(prefs: ^config.Prefs, s: ^ui.State, t: Standard_Targets = {}) {
	for e in prefs.entries {
		if e.source != .Default { standard_apply_one(prefs, s, t, e.def.name) }
	}
}

// standard_apply now, then again for each standard preference that changes (config.watch: a change applies that one
// alone, at once, on the thread that changed it; nothing runs per frame). Keep `w` where it is until standard_unwatch.
Standard_Watch :: struct {
	prefs: ^config.Prefs,
	s:     ^ui.State,
	t:     Standard_Targets,
	id:    int,
}

standard_watch :: proc(w: ^Standard_Watch, prefs: ^config.Prefs, s: ^ui.State, t: Standard_Targets = {}) {
	w^ = {prefs = prefs, s = s, t = t}
	standard_apply(prefs, s, t)
	w.id = config.watch(prefs, "", proc(user: rawptr, name: string, p: ^config.Prefs) {
		w := (^Standard_Watch)(user)
		standard_apply_one(p, w.s, w.t, name)
	}, w)
}

standard_unwatch :: proc(w: ^Standard_Watch) {
	if w.prefs != nil && w.id != 0 { config.unwatch(w.prefs, w.id) }
	w^ = {}
}

// A number of the registry, Int or Float (ok false: not registered, or not a number).
@(private = "file")
number_value :: proc(prefs: ^config.Prefs, name: string) -> (v: f64, ok: bool) {
	r := config.ref_of(prefs, name)
	if r == config.NO_REF { return }
	e := config.entry(prefs, r)
	#partial switch e.def.kind {
	case .Int:   return f64(e.value.i), true
	case .Float: return e.value.f, true
	}
	return
}

// The index of a String preference's value in `choices` (ok false: not registered, or none of them).
@(private = "file")
choice_value :: proc(prefs: ^config.Prefs, name: string, choices: []string) -> (at: int, ok: bool) {
	r := config.ref_of(prefs, name)
	if r == config.NO_REF || config.entry(prefs, r).def.kind != .String { return }
	v := config.get_string(prefs, r)
	for c, i in choices { if c == v { return i, true } }
	return
}

@(private = "file")
bool_value :: proc(prefs: ^config.Prefs, name: string) -> (v: bool, ok: bool) {
	r := config.ref_of(prefs, name)
	if r == config.NO_REF || config.entry(prefs, r).def.kind != .Bool { return }
	return config.get_bool(prefs, r), true
}

// One preference to its setter: what a change of it applies (the others of a struct it is part of stay as they are, so
// that a zoom by Ctrl+wheel is not undone by a change of the density).
@(private = "file")
standard_apply_one :: proc(prefs: ^config.Prefs, s: ^ui.State, t: Standard_Targets, name: string) {
	switch {
	case strings.has_prefix(name, "appearance.text."): apply_text(prefs, t, name)
	case strings.has_prefix(name, "appearance.") || strings.has_prefix(name, "window."): apply_appearance(prefs, s, t, name)
	case strings.has_prefix(name, "scrolling."): apply_scrolling(prefs, s, name)
	case strings.has_prefix(name, "input.") || strings.has_prefix(name, "timing."): apply_feel(prefs, s, name)
	case strings.has_prefix(name, "rendering."): apply_rendering(prefs, s, t, name)
	}
}

@(private = "file")
apply_appearance :: proc(prefs: ^config.Prefs, s: ^ui.State, t: Standard_Targets, name: string) {
	switch name {
	case "appearance.zoom":     if v, ok := number_value(prefs, name); ok { ui.set_zoom(s, f32(v)) }
	case "appearance.density":  if v, ok := number_value(prefs, name); ok { ui.set_density(s, f32(v)) }
	case "appearance.rounding": if v, ok := number_value(prefs, name); ok { ui.set_rounding(s, f32(v)) }
	case "appearance.corner_smoothing":
		if v, ok := number_value(prefs, name); ok && t.renderer != nil { render.set_corner_smoothing(t.renderer, f32(v)) }
	case "appearance.animations":
		if i, ok := choice_value(prefs, name, ANIMATION_CHOICES[:]); ok { ui.set_animations(s, ui.Animations(i)) }
	case "window.toast_position":
		if i, ok := choice_value(prefs, name, TOAST_CHOICES[:]); ok { ui.set_toast_position(s, ui.Toast_Position(i)) }
	}
}

@(private = "file")
apply_scrolling :: proc(prefs: ^config.Prefs, s: ^ui.State, name: string) {
	sc := ui.scroll_settings(s)
	au := ui.autoscroll_settings(s)
	f := ui.feel(s)
	v, num := number_value(prefs, name)
	b, is_bool := bool_value(prefs, name)
	switch name {
	case "scrolling.smooth":
		if i, ok := choice_value(prefs, name, SMOOTH_CHOICES[:]); ok { ui.set_smooth_scroll(s, ui.Smooth_Scroll(i)) }
		return
	case "scrolling.curve":
		if i, ok := choice_value(prefs, name, CURVE_CHOICES[:]); ok { sc.curve = ui.Scroll_Curve(i) }
	case "scrolling.duration":         if num { sc.duration_ms = f32(v) }
	case "scrolling.impulse":          if num { sc.impulse = f32(v) }
	case "scrolling.wheel_lines":      if num { f.wheel_lines = f32(v) }
	case "scrolling.fling_stop_speed": if num { f.fling_stop_speed = f32(v) }
	case "scrolling.autohide_scrollbars": if is_bool { ui.set_scrollbar_autohide(s, b) }; return
	case "scrolling.scrollbar_arrows":    if is_bool { ui.set_scrollbar_arrows(s, b) }; return
	case "scrolling.autoscroll.enabled":  if is_bool { ui.set_autoscroll_enabled(s, b) }; return
	case "scrolling.autoscroll.toggle":    if is_bool { au.toggle = b }
	case "scrolling.autoscroll.dead_zone": if num { au.dead_zone = f32(v) }
	case "scrolling.autoscroll.max_speed": if num { au.max_speed = f32(v) }
	case "scrolling.autoscroll.full_dist": if num { au.full_dist = f32(v) }
	case "scrolling.autoscroll.doubling":  if num { au.doubling = f32(v) }
	case "scrolling.autoscroll.tap":       if num { au.tap_ms = f32(v) }
	case "scrolling.autoscroll.tap_slop":  if num { au.tap_slop = f32(v) }
	case: return
	}
	if sc != ui.scroll_settings(s) { ui.set_scroll_settings(s, sc) }
	if au != ui.autoscroll_settings(s) { ui.set_autoscroll_settings(s, au) }
	if f != ui.feel(s) { ui.set_feel(s, f) }
}

@(private = "file")
apply_feel :: proc(prefs: ^config.Prefs, s: ^ui.State, name: string) {
	v, ok := number_value(prefs, name)
	if !ok { return }
	f := ui.feel(s)
	ms := int(math.round(v))
	switch name {
	case "input.key_repeat_delay":       f.key_repeat_delay_ms = ms
	case "input.key_repeat_rate":        f.key_repeat_rate = ms
	case "input.button_repeat_delay":    f.repeat_delay_ms = ms
	case "input.button_repeat_interval": f.repeat_interval_ms = ms
	case "input.undo_steps":             f.undo_steps = ms
	case "input.undo_merge":             f.undo_merge_ms = ms
	case "input.typeahead":              f.typeahead_ms = ms
	case "input.zoom_step":              f.zoom_step = f32(v)
	case "input.step_shift":             f.step_shift = v
	case "input.step_ctrl":              f.step_ctrl = v
	case "input.step_alt":               f.step_alt = v
	case "input.step_page":              f.step_page = v
	case "timing.tooltip_delay":         f.tooltip_delay_ms = ms
	case "timing.menu_hover":            f.menu_hover_ms = ms
	case "timing.menu_item_height":      f.menu_item_em = f32(v)
	case "timing.palette_fade":          f.palette_fade_ms = ms
	case: return
	}
	if f != ui.feel(s) { ui.set_feel(s, f) }
}

@(private = "file")
apply_text :: proc(prefs: ^config.Prefs, t: Standard_Targets, name: string) {
	if r := t.renderer; r != nil {
		tr := render.text_rendering(r)
		v, num := number_value(prefs, name)
		switch name {
		case "appearance.text.gamma":             if num { tr.gamma = f32(v) }
		case "appearance.text.contrast":          if num { tr.contrast = f32(v) }
		case "appearance.text.coverage_exponent": if num { tr.coverage_exponent = f32(v) }
		case "appearance.text.curve":
			if i, ok := choice_value(prefs, name, TEXT_CURVE_CHOICES[:]); ok { tr.curve = render.Text_Curve(i) }
		case "appearance.text.blend_space":
			// (the program shows its theme again in the new space: ui.theme_show's key holds it)
			if i, ok := choice_value(prefs, name, BLEND_CHOICES[:]); ok && render.blend_space(r) != render.Blend_Space(i) { render.set_blend_space(r, render.Blend_Space(i)) }
		}
		if tr != render.text_rendering(r) { render.set_text_rendering(r, tr) }
	}
	fs := t.fonts
	if fs == nil { return }
	st := fs.settings
	v, num := number_value(prefs, name)
	b, is_bool := bool_value(prefs, name)
	n := int(math.round(v))
	switch name {
	case "appearance.text.system_fallback": if is_bool { st.system_fallback = b }
	case "appearance.text.color_emoji":     if is_bool { st.color_glyphs = b }
	case "appearance.text.color_async":     if is_bool { st.color_async = b }
	case "appearance.text.subpixel":
		if i, ok := choice_value(prefs, name, SUBPIXEL_CHOICES[:]); ok { st.subpixel_text = font.Subpixel_Text(i) }
	case "appearance.text.subpixel_steps":  if num { st.subpixel_steps = n }
	case "appearance.text.grid_fit":
		if i, ok := choice_value(prefs, name, GRID_FIT_CHOICES[:]); ok { st.grid_fit = font.Grid_Fit(i) }
	case "appearance.text.renderer":
		if i, ok := choice_value(prefs, name, RENDERER_CHOICES[:]); ok { st.text_renderer = font.Text_Renderer(i) }
	case "appearance.text.rendering":
		if i, ok := choice_value(prefs, name, RENDERING_CHOICES[:]); ok { st.rendering = font.Rendering(i) }
	case "appearance.text.slug_tolerance":  if num { st.slug_tolerance = f32(v / SLUG_TOLERANCE_UNIT) }
	case "appearance.text.atlas_pages":     if num { st.max_gray_pages = n }
	case "appearance.text.color_pages":     if num { st.max_color_pages = n }
	case "appearance.text.word_cache":      if num { st.word_cache = n }
	case "appearance.text.slug_pages":      if num { st.slug_pages = n }
	case: return   // (page_size: read by font.init only, at the next start)
	}
	if st != fs.settings { font.set_settings(fs, st) }
}

@(private = "file")
apply_rendering :: proc(prefs: ^config.Prefs, s: ^ui.State, t: Standard_Targets, name: string) {
	if name == "rendering.partial_redraw" {
		if b, ok := bool_value(prefs, name); ok {
			if t.partial_redraw != nil { t.partial_redraw^ = b } else { ui.set_partial_redraw(s, b) }
		}
		return
	}
	r := t.renderer
	if r == nil { return }
	v, num := number_value(prefs, name)
	switch name {
	case "rendering.present":
		if i, ok := choice_value(prefs, name, PRESENT_CHOICES[:]); ok { render.set_present_mode(r, render.Present_Mode(i)) }
	case "rendering.max_frame_latency": if num { _ = render.set_max_frame_latency(r, int(v)) }
	case "rendering.blur_sigma_limit":  if num { render.set_blur_sigma_limit(r, f32(v)) }
	case "rendering.filter_precision":
		if i, ok := choice_value(prefs, name, FILTER_CHOICES[:]); ok { render.set_filter_precision(r, render.Target_Format(i)) }
	}
}
