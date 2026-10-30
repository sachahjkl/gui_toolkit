// Package ui: retained-state immediate-mode UI core (a port of raddebugger's ui layer, written in Odin).
//
// The model, in short:
//   * Every frame the app rebuilds a tree of `Box`es between `begin_build` and `end_build`.
//   * A box has a stable `Key` (hash of its id string under its parent). Boxes persist across frames in a table keyed by
//     that key, which is where hover/press animation, scroll offsets and text-field state survive rebuilds.
//   * Layout runs after the build: sizes are `Size`s (pixels, text, percent of parent, sum of children) resolved in the
//     same passes as raddebugger (standalone, upward-dependent, downward-dependent, violation solving, positions).
//   * Widgets return a `Signal` computed from last frame's layout and this frame's input.
//   * Style (font, sizes, padding, tags for the theme, ...) is a stack: `if style({...}) { ... }` overrides it for a
//     block, `next({...})` overrides it for the next box only.
package ui

import "core:mem/virtual"
import "../draw"
import "../font"
import "../platform"

Vec2  :: draw.Vec2
Rect  :: draw.Rect
Color :: draw.Color

Axis :: enum u8 { X, Y }

Key :: distinct u64

////////////////////////////////
// Sizes

Size_Kind :: enum u8 {
	None,
	Pixels,         // value px
	Text,           // text width/height + (text_pad + value) px of padding on each side
	Percent,        // value (0..1) of the nearest sized ancestor
	Children_Sum,   // sum (along the layout axis) or max (across it) of the children
}

Size :: struct {
	kind:       Size_Kind,
	value:      f32,
	strictness: f32,   // 0 = shrinks freely when space runs out, 1 = never shrinks
}

px :: proc(v: f32, strictness: f32 = 1) -> Size { return {.Pixels, v, strictness} }
text_size :: proc(padding: f32 = 0, strictness: f32 = 1) -> Size { return {.Text, padding, strictness} }
pct :: proc(p: f32, strictness: f32 = 0) -> Size { return {.Percent, p, strictness} }
children_sum :: proc(strictness: f32 = 1) -> Size { return {.Children_Sum, 0, strictness} }
fill :: proc() -> Size { return pct(1, 0) }

////////////////////////////////
// Boxes

Box_Flag :: enum u8 {
	Clickable,
	Focusable,           // a Tab stop: can own keyboard focus; Enter / Space activate it unless it is a Text_Input
	Text_Input,          // handles keys and text itself (line_edit, text_edit): no Enter / Space activation
	Scroll_Self,         // receives wheel deltas in `signal(...).scrolled` and scrolls its own content
	View_Scroll_X,
	View_Scroll_Y,
	View_Clamp_X,
	View_Clamp_Y,
	Allow_Overflow_X,    // children may exceed this box along X without being shrunk
	Allow_Overflow_Y,
	Floating_X,          // positioned by `fixed_pos`, ignored by the parent's layout
	Floating_Y,
	Clip,
	Disabled,
	Draw_Background,
	Draw_Border,
	Draw_Text,
	Draw_Shadow,
	Draw_Hot_Effects,    // hover / press fill over the box (theme: "hover_fill", "press_fill", "hover_border")
	Draw_Focus_Ring,
	Draw_Side_Top,
	Draw_Side_Bottom,
	Draw_Side_Left,
	Draw_Side_Right,
	No_Text_Trunc,       // never replace overflowing text with "..."
	Fixed_Radius,        // the radius is part of the shape (colour dot, avatar): not scaled by the rounding setting
	Wrap,                // children flow left to right and wrap onto new lines when the box is too narrow (see `flow`)
	Text_Wrap,           // the text wraps onto lines at the box's width; a .Text height is that of all its lines (`paragraph`)
	Window_Caption,      // part of an integrated title bar: where nothing clickable is over it, it drags the window (`title_bar`)
	Hot_Within,          // hot (hot_t, its hover fill) also while the pointer is on a clickable box inside it (a row and its buttons)
	Scrollbar_Left,      // a .View_Scroll_Y box's scrollbar is at its left edge (a panel docked on the right side keeps it on the outside)
	Selectable,          // its text (a label, a paragraph, a rich paragraph) can be selected and copied (selection.odin)
	Middle_Click,        // handles the middle button itself (a tab closes): a middle press on it does not start autoscroll in the region it is in
}
Box_Flags :: bit_set[Box_Flag; u64]

Text_Align :: enum u8 { Left, Center, Right }

// How children are placed across the parent's layout axis.
Cross_Align :: enum u8 { Start, Center, End }

Custom_Draw :: proc(box: ^Box, user: rawptr, dc: ^draw.Context)

Box :: struct {
	// tree (rebuilt every frame)
	first, last, next, prev, parent: ^Box,
	child_count: int,

	// identity / persistence
	key:         Key,
	name:        string,         // hash part of the id string ("" for anonymous boxes), for debugging and tests
	last_build:  u64,
	first_build: u64,

	// inputs from the build
	flags:       Box_Flags,
	pref:        [Axis]Size,
	layout_axis: Axis,
	cross:       Cross_Align,
	gap:         Vec2,           // .Wrap boxes: horizontal space between items, vertical space between lines
	wrap_line:   int,            // .Wrap children: line index (set by the X layout pass, used by the Y one)
	fixed_pos:   Vec2,           // for Floating_X / Floating_Y, relative to the parent's top-left
	text:        string,         // display string (arena-allocated, valid for this frame)
	font:        font.Font_Id,
	font_size:   f32,
	text_pad:    f32,
	text_align:  Text_Align,
	radius:      f32,
	squish:      f32,
	transparency: f32,
	cursor:      platform.Cursor,
	tags_key:    Key,            // identifies the tag stack the box was built under (for theme lookups while drawing)
	custom:      Custom_Draw,
	custom_user: rawptr,
	measure_y:   proc(b: ^Box) -> f32,   // a .Text height that depends on the width the X pass gave (rich_paragraph)
	slant:       platform.Slant,   // a Clickable box whose sides lean (a trapezoid tab): only that shape is hit (reset each build)

	// colors: targets from the theme, and the animated values actually drawn
	target_bg, target_border, target_text: Color,
	bg, border, text_color:                Color,

	// layout results
	size:        Vec2,           // computed size
	rel_pos:     Vec2,           // position relative to the parent's origin
	rect:        Rect,           // final screen rect
	text_dim:    Vec2,           // measured size of `text` (without padding)
	view_off:    Vec2,           // scroll offset, animated
	view_target: Vec2,           // scroll offset target
	view_bounds: Vec2,           // extent of the children (for clamping)
	view_anim:   [2]Scroll_Anim, // smooth scrolling toward view_target (scroll_anim.odin)

	// animation (0..1)
	hot_t, active_t, disabled_t, focus_t: f32,

	// accessibility (a11y.odin): what it is to screen readers, set by its widget or the app (this build's arena)
	a11y:        ^A11y_Info,
}

////////////////////////////////
// Signals

Signal :: struct {
	box:             ^Box,
	mouse:           Vec2,    // mouse position relative to the box
	hovering:        bool,
	pressed:         bool,    // left press began on this box this frame
	released:        bool,
	clicked:         bool,    // left press and release both on this box
	double_clicked:  bool,
	right_clicked:   bool,
	middle_clicked:  bool,
	dragging:        bool,    // left button is held and this box was pressed
	drag_delta:      Vec2,    // since the press
	scrolled:        Vec2,    // wheel delta consumed by this box
	focused:         bool,    // owns keyboard focus
	mods:            platform.Modifiers,
}

////////////////////////////////
// Style stack

Style :: struct {
	pref:         [Axis]Size,
	font:         font.Font_Id,
	font_size:    f32,
	text_pad:     f32,
	text_align:   Text_Align,
	radius:       f32,
	transparency: f32,
	squish:       f32,
	extra_flags:  Box_Flags,
	cursor:       platform.Cursor,
}

// Optional overrides: set only the fields you want. `fixed_*` position/size a box (and make it floating).
Style_Mod :: struct {
	width, height: Maybe(Size),
	font:          Maybe(font.Font_Id),
	font_size:     Maybe(f32),
	text_pad:      Maybe(f32),
	text_align:    Maybe(Text_Align),
	radius:        Maybe(f32),
	transparency:  Maybe(f32),
	squish:        Maybe(f32),
	flags:         Box_Flags,                // added to every box built under this style
	cursor:        Maybe(platform.Cursor),
	axis:          Maybe(Axis),              // child layout axis (applies to the box itself, not inherited)
	cross:         Maybe(Cross_Align),       // child alignment across that axis (next box only)
	gap:           Maybe(Vec2),              // .Wrap boxes: spacing between items / lines (next box only)
	fixed_x:       Maybe(f32),
	fixed_y:       Maybe(f32),
	fixed_w:       Maybe(f32),
	fixed_h:       Maybe(f32),
	bg:            Maybe(Color),             // explicit color overrides (skip the theme)
	border:        Maybe(Color),
	fg:            Maybe(Color),
}

// Theme: (tags -> color) patterns. A pattern applies when its last tag equals the queried name and all its other tags
// are on the tag stack; the pattern with the most tags wins, ties go to the first one in the list.
Theme_Pattern :: struct {
	tags:   []string,   // slices of `source`
	color:  Color,
	source: string,     // the text `tags` came from: a copy the theme owns
}

// How raised surfaces (buttons, bars, selected items) are painted.
Finish :: enum u8 {
	Flat,       // plain colour
	Gradient,   // vertical gradient, highlight line along the top edge, embossed text, glowing focus (Bootstrap 2)
	Glass,      // glossy upper half, glow at the bottom, white inner rim (Windows 7 Aero)
}

// Interaction states (hover, press, focus, selection, disabled) show at once by default: the frame that sees the pointer
// enter a box draws it hot, with no fade in or out. `transition_ms` > 0 brings back short cross-fades of those states;
// `press_squish` > 0 shrinks a pressed button by that fraction (at once, no animation). A change of palette still
// cross-fades every colour for PALETTE_FADE_MS (apply_palette bumps `serial`).
Theme :: struct {
	patterns:      [dynamic]Theme_Pattern,
	palette_at:    int,    // apply_palette: where its entries start in `patterns` (after any the app added before)
	palette_made:  bool,
	finish:        Finish,
	transition_ms: f32,   // 0: states change at once (default)
	press_squish:  f32,   // 0: none (default); 0.04 is the old press "squish"
	serial:        u64,   // bumped when a colour changes (theme_add, theme_set, apply_palette)
}

Timer :: struct {
	next_ms:    f64,
	last_build: u64,
}

Toast_Kind :: enum u8 { Info, Good, Warn, Bad }

Toast :: struct {
	alive:   bool,
	serial:  u64,      // unique per toast: keys its position animation (birth times can be equal)
	kind:    Toast_Kind,
	text:    [112]u8,
	len:     int,
	born_ms: f64,
	life_ms: f64,
}

Focus_Entry :: struct {
	key:     Key,
	trapped: bool,
}

Animation :: struct {
	value:      f32,
	last_build: u64,
}

Events :: struct {
	list:     [dynamic]platform.Event,
	consumed: [dynamic]bool,
}

State :: struct {
	// persistent
	boxes:       map[Key]^Box,
	free_boxes:  [dynamic]^Box,
	anims:       map[Key]Animation,
	arena:       virtual.Arena,
	build_index: u64,
	zoom:        f32,                // user zoom factor (Ctrl+wheel, Ctrl +/-/0); multiplies the DPI scale
	scale:       f32,                // effective scale = dpi scale * zoom, applied to every logical size
	root:        ^Box,
	theme:       ^Theme,
	fonts:       ^font.State,
	icon_font:   font.Font_Id,
	mono_font:   font.Font_Id,           // optional: used by sliders, kbd chips and tables (falls back to the UI font)
	timers:      map[Key]Timer,
	drag_payload: [4]f32,               // data stored at press time for the active drag (see drag_store / drag_load)
	toasts:      [8]Toast,
	toast_pos:   Toast_Position,
	toast_serial: u64,
	toast_area:  Rect,
	toast_area_set: bool,
	bar_keys:    [dynamic]Key,          // menu bar menus built this frame
	bar_keys_prev: [dynamic]Key,

	// per build
	parent_stack: [dynamic]^Box,
	style_stack:  [dynamic]Style,
	tag_stack:    [dynamic]string,
	disabled_stack: [dynamic]bool,   // `disabled` scopes; disabled_depth counts the true ones
	disabled_depth: int,
	disabled_keep:  f32,             // opacity of disabled widgets for the current theme (set by draw_tree)
	space:          draw.Blend_Space, // what the tree is drawn into (set by draw_tree): translucent colors adapt (tuned)
	backdrop:       Color,           // the theme's background (set by draw_tree): what `tuned` assumes is under a color
	tag_marks:    [dynamic]int,       // tag stack depth to restore on pop (for `tags` scopes)
	tag_keys:     [dynamic]Key,       // running hash of the tag stack (tag_keys[i] covers tag_stack[:i+1])
	tag_sets:     map[Key][]string,   // per-frame: tag stack contents by key, for theme lookups while drawing
	color_memo:   map[[2]u64]Color,   // per-frame: (tags key, name hash) -> resolved color
	next_mod:     Style_Mod,
	has_next:     bool,
	overlay_root: ^Box,
	anim_rate:    f32,                // exponential rate multiplier: 0 disables animation (values jump)
	scroll_smooth: bool,              // scrolling glides (Build_Params.smooth_scroll)
	dt:           f32,
	window_size:  Vec2,
	boxes_built:  int,
	anim_busy:    bool,
	wake_ms:      int,                // ask the app loop for a timed wake (caret blink)
	theme_serial: u64,                // Theme.serial seen by the last build
	fade_until_ms: f64,               // box colours cross-fade until then (a palette change), else they jump

	// input
	events:      Events,
	typed:       [dynamic]rune,
	mouse:       Vec2,
	mouse_valid: bool,
	mods:        platform.Modifiers,
	hot_key:     Key,
	active_key:  [platform.Mouse_Button]Key,
	press_pos:   [platform.Mouse_Button]Vec2,
	pressed_key:  [platform.Mouse_Button]Key,
	pressed_any:  [platform.Mouse_Button]bool,   // a press happened this frame (even on nothing clickable)
	released_key: [platform.Mouse_Button]Key,
	clicked_key:  [platform.Mouse_Button]Key,
	double_key:   Key,
	scroll_delta: Vec2,
	scroll_key:   Key,
	last_click_key:  Key,
	last_click_ms:   f64,
	focus_key:    Key,
	focus_visible: bool,             // focus came from the keyboard: draw the focus ring on any focused box
	focus_order:  [dynamic]Focus_Entry,  // Tab stops in build order (this frame)
	trap_depth:   int,               // > 0 while building inside a modal: Tab cycles inside it only
	tab_stops_off: [dynamic]bool,    // `tab_stops` scopes; tab_skip counts the ones that turned Tab stops off
	tab_skip:     int,
	modal_prev, modal_now: Key,      // modal open last frame / this frame (focus resets when a modal opens)
	tab_dir:      int,               // +1 / -1: the focus moved by Tab / Shift+Tab this frame (0: it did not)
	sb_owner:     map[Key]Key,       // scrollbar key -> key of the scroll box it belongs to
	sb_grab:      f32,               // pointer offset inside the thumb while dragging it
	density:      f32,               // vertical compactness: 1 = comfortable, lower = denser rows and gaps (see `dense`)
	rounding:     f32,               // corner rounding factor applied to every rounded shape (0 = square, 1 = default)
	time_ms:      f64,
	inactive:     bool,              // Build_Params.inactive: the window is not the user's: carets are hidden and still
	cursor_request: platform.Cursor,
	clipboard_get: proc() -> string,
	clipboard_set: proc(text: string),

	// popups
	menu_item_em:    f32,                   // height of a menu item in em (0 = the default, MENU_ITEM_EM); set_menu_item_height
	menus:           [dynamic]Menu_Level,   // the open menu and its open submenus, outermost first (menu.odin)
	menu_build:      [dynamic]int,          // levels whose items are being built (innermost last)
	menu_close_pending: bool,               // an item was chosen: the menu closes when its block ends, not in the middle of it
	menu_keys:       Events,                // key presses and text of this frame while a menu is open: the menu owns them
	popup_stack:     [dynamic]bool,   // one entry per open popup scope: did it push parents/tags?
	hover_since_ms:  f64,
	hover_key:       Key,
	mouse_moved:     bool,            // the pointer moved this frame
	list_stack:      [dynamic]^List_State,  // lists being built (list.odin)

	// integrated title bar (window_chrome.odin)
	window:          ^platform.Window,      // Build_Params.window: gets the title bar regions after each build
	chrome:          platform.Chrome_Regions,
	caption_keys:    [platform.Caption_Button]Key,
	caption_built:   bool,                  // a box with .Window_Caption was built this build
	caption_font:    font.Font_Id,
	caption_font_tried: bool,

	// smooth scrolling of scroll regions (scroll_anim.odin)
	scroll_cfg:      Scroll_Settings,
	scroll_cfg_set:  bool,
	frame_ms:        f64,                   // the frame's time (Build_Params.frame_ms, else now_ms)

	// middle-click autoscroll of scroll regions (autoscroll.odin): the one active session, the area it drives, its
	// settings, and whether it is enabled at all. `auto_box` is the scroll box the session scrolls (0 when none).
	auto:            Autoscroll,
	auto_box:        Key,
	auto_cfg:        Autoscroll_Settings,
	auto_cfg_set:    bool,
	auto_enabled:    bool,       // set_autoscroll_enabled; off by default (an app opts in, so nothing changes silently)
	auto_pressed:    bool,       // a middle press this frame started (or could start) a session: set in process_events

	// wrapped text: lines by (text, font, size, width), kept while used (text_wrap.odin)
	wrap_cache:      map[Wrap_Key]Wrap_Entry,
	// rich text: layouts by content, the faces of bold / italic runs, the link each focused paragraph is on (rich_text.odin)
	rich_cache:      map[u64]Rich_Cache_Entry,
	rich_faces:      map[font.Font_Id][4]font.Font_Id,
	rich_link:       map[Key]int,
	// find in page: the needle, the matches of the last layout (find.odin)
	find:            Find_State,
	// selection of text outside fields (selection.odin), and this build's mouse presses / releases it reads
	sel:             Selection,
	mouse_events:    [dynamic]platform.Event,
	// calls posted from other threads (post.odin)
	posts:           Post_Queue,
	post_budget:     int,                   // calls a build runs at most
	posts_more:      bool,                  // the last drain left some: needs_frame
	post_wake_own:   bool,                  // set_post_wake gave the app's own wake: Build_Params.window does not replace it
	// accessibility: the tree screen readers read, the requests they made (a11y.odin)
	a11y:            A11y_Data,
}
