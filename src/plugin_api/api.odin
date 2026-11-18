// Package plugin_api: what a plugin's JavaScript reaches, declared once (src/md/features/plugins.md, decision 3). A
// declaration is the struct of a call's arguments, and one entry of DECLARATIONS names its module, its JavaScript name,
// the capability it needs and the level that added it. The bridge (bridge.odin) makes every call from these, and
// `tk plugin_api` writes the `.d.ts`, the reference page and the explorer's JSON from the same text.
//
// Rules of this file, which `tk plugin_api` relies on: a declaration's struct and the types of its fields are declared
// here; a field's type is string, f64, int, bool, Handler, an enum or a struct of this file; a field tagged `optional`
// may be absent. The doc comment above each type is its text in the reference.
package tk_plugin_api

import js "../js"

// The level of the API this toolkit gives, and the oldest a plugin may ask: a manifest's `api` between the two is
// accepted. A level only adds; a removal or a change raises the oldest.
PLUGIN_API_LEVEL :: 7
PLUGIN_API_OLDEST :: 1

// What a call needs the person to have granted (the manifest's "permissions"). `.None`: nothing. The bridge refuses a
// call without its grant at once (PermissionError); the program's broker checks again, and checks what depends on the
// arguments (a path's folder, an address's origin).
Capability :: enum u8 {
	None,
	Files,             // "files": the files and folders the person picks in the system's dialog
	Documents,         // "folder:documents"
	Downloads,         // "folder:downloads"
	Net,               // "net:<origin>" or "net:*": the addresses of the origins named, or any public one
	Clipboard_Read,    // "clipboard.read": only while the person acts in the plugin (a command, a click in its view)
	Clipboard_Write,   // "clipboard.write"
}

// What a call gives back to JavaScript.
Result :: enum u8 {
	Undefined,
	Setting_Value,      // a boolean, a number or a string: what the implementation returns
	Promise_Text,       // a promise of a string
	Promise_Void,       // a promise of nothing
	Promise_Path,       // a promise of a path, or null when the person picked nothing
	Promise_Response,   // a promise of a Fetch_Response
}

// A function of the plugin (commands.on's handler). The bridge checks that it is callable; the host retains it
// (js.retain) for as long as it keeps it.
Handler :: distinct js.Value

// Registers the handler of one of the manifest's commands: choosing the command in the palette calls it. A second
// call for the same command replaces the handler.
Commands_On :: struct {
	// The command's id, as the manifest's `commands` declares it.
	id:      string,
	// Called with no argument when the command is chosen. It may return a promise.
	handler: Handler,
}

// How a toast looks.
Toast_Kind :: enum u8 {
	info,
	good,
	warn,
	bad,
}

// A toast's options.
Toast_Options :: struct {
	// Its look ("info" when absent).
	kind:  Toast_Kind `optional`,
	// A line in bold above the text.
	title: string `optional`,
}

// Shows a message to the person: a toast of the window, or the system's notification when the program says its
// messages there.
Toast_Show :: struct {
	// What it says.
	text:    string,
	options: Toast_Options `optional`,
}

// What the entry file's activate(context) is given (gt:plugins makes it: plugins/runtime.odin, context_object).
Activate_Context :: struct {
	// The plugin's id, as plugin.json says it.
	id:      string,
	// Its name.
	name:    string,
	// Its version ("" when plugin.json says none).
	version: string,
	// The level of the API this program gives.
	api:     int,
	// The person's language, as the toolkit's tag ("fr", "fr-CA"; "en": English). It changes while the plugin runs
	// when the person changes it: every open view renders again then.
	language: string `level=7`,
}

////////////////////////////////
// Views (level 2): a render returns a tree of nodes; the host writes it as a display list (display.odin) and replays it
// in the window. Each node is an object with its `kind`, an optional `key` (unique in the view; a node without one is
// keyed by its place), and the fields of its kind's struct below.

// A function of the plugin called with a field's text (a field's onChange and onSubmit).
Text_Handler :: distinct js.Value

// A function of the plugin called with a box's new state (a check box's or a switch's onChange).
Flag_Handler :: distinct js.Value

// A view's render: called with no argument, it returns the view's tree (a Node). It runs when the view opens, after
// each of the view's handlers, and after views.update.
Render :: distinct js.Value

// The nodes inside a row, a column or a card: an array.
Children :: distinct js.Value

// Registers the render of one of the manifest's views. A second call for the same view replaces it.
Views_Register :: struct {
	// The view's id, as the manifest's `views` declares it.
	id:     string,
	render: Render,
}

// Asks for the view's render again, after the current handler: the plugin's state changed outside a handler of the
// view (a command, a promise that settled).
Views_Update :: struct {
	// The view's id.
	id: string,
}

// What a button's colour says.
Button_Intent :: enum u8 {
	neutral,
	primary,
	success,
	warning,
	danger,
}

// How a button sits: `raised` has a face of its own; `ghost` none until the pointer is over it (an act repeated in
// each row of a list); `link` reads as a link.
Button_Look :: enum u8 {
	raised,
	ghost,
	link,
}

// A button's size, all its measures together; `small` for an act in each row of a list, `large` for the one act of a
// view.
Button_Size :: enum u8 {
	medium,
	small,
	large,
}

// A step of the toolkit's spacing scale; `fill` takes the room left in a row.
Space_Size :: enum u8 {
	small,
	medium,
	large,
	fill,
}

// A Lucide icon by its name ("search", "alert-triangle": lucide.dev's names, as the toolkit's font has them; level 6).
// An unknown name draws nothing, and the plugin's log says it once.
Icon_Name :: distinct string

// A word to find, or several: each occurrence is marked (level 6).
Words :: distinct string

// What a text's colour says, by the theme (level 6). `weak` is the old `weak: true`; `info` the accent's colour.
Tone :: enum u8 {
	plain,
	info,
	good,
	warn,
	bad,
	weak,
}

// A paragraph of text; it wraps in a column.
Text_Node :: struct {
	text:      string,
	// Drawn in the weak colour.
	weak:      bool `optional`,
	// Its colour, by what it says.
	tone:      Tone `optional level=6`,
	// In the monospace face (a time, an id, a number that changes).
	mono:      bool `optional level=6`,
	// An icon before it.
	icon:      Icon_Name `optional level=6`,
	// Each occurrence of the word, or of each word, case aside (ASCII letters), marked as the find bar marks.
	highlight: Words `optional level=6`,
}

// A title of a part of the view.
Heading_Node :: struct {
	text: string,
	// An icon before it.
	icon: Icon_Name `optional level=6`,
}

// A short state, a count or a kind, in the colour of its tone: a mark, not a button (it takes no press).
Badge_Node :: struct {
	text: string,
	tone: Tone `optional`,
	icon: Icon_Name `optional`,
}

// A button.
Button_Node :: struct {
	label:    string,
	// A glyph before its words.
	icon:     Icon_Name `optional level=6`,
	intent:   Button_Intent `optional`,
	// How it sits and its size. A program older than these fields shows a raised, medium button.
	look:     Button_Look `optional`,
	size:     Button_Size `optional`,
	disabled: bool `optional`,
	// Called when it is pressed.
	onClick:  Handler `optional`,
}

// Its children side by side.
Row_Node :: struct {
	children: Children `optional`,
}

// Its children one under the other.
Column_Node :: struct {
	children: Children `optional`,
}

// A titled panel around its children, as wide as the view.
Card_Node :: struct {
	title:    string `optional`,
	children: Children `optional`,
}

// Room between two nodes ("small" when absent).
Space_Node :: struct {
	size: Space_Size `optional`,
}

// A line of text the person types. The host keeps what is typed: a value the plugin gives is shown unless the person
// typed since the plugin last heard of it. Without a value, the field keeps its own text.
Field_Node :: struct {
	value:       string `optional state`,
	placeholder: string `optional`,
	// A glyph at its start, inside it ("search").
	icon:        Icon_Name `optional level=6`,
	// Called with the text at each change.
	onChange:    Text_Handler `optional`,
	// Called with the text when Enter is pressed.
	onSubmit:    Text_Handler `optional`,
}

// A check box and its words.
Check_Node :: struct {
	label:    string,
	checked:  bool `optional state`,
	// Called with its new state when the person changes it.
	onChange: Flag_Handler `optional`,
}

// A switch and its words.
Switch_Node :: struct {
	label:    string,
	on:       bool `optional state`,
	// A glyph before it.
	icon:     Icon_Name `optional level=6`,
	// Called with its new state when the person changes it.
	onChange: Flag_Handler `optional`,
}

// A line across the view.
Separator_Node :: struct {}

// A list's row: called with a row's index, it returns that row's node (level 5). The program calls it only for the rows
// in view and a margin, as the person scrolls.
Row_Render :: distinct js.Value

// A list of `count` rows that the program asks for by range, only those in view and a margin: a list of a million rows
// costs what its screen shows. A row not answered yet shows a placeholder. Change `version` when the rows' content
// changes: the rows kept are dropped and asked again (an answer for an older version is dropped).
Lazy_List_Node :: struct {
	// How many rows it has (1 000 000 at most).
	count:       int,
	// Its rows' content: rows kept for another version are dropped.
	version:     int `optional`,
	// A row's height in lines of text, before its rows are measured (2 when absent).
	rowHeight:   f64 `optional`,
	// How many rows high the list is (10 when absent).
	visibleRows: int `optional`,
	// Each row's node.
	row:         Row_Render,
}

// The kinds of nodes, in the order of NODES.
Node_Kind :: enum u8 {
	Text,
	Heading,
	Button,
	Row,
	Column,
	Card,
	Space,
	Field,
	Check,
	Switch,
	Separator,
	List,
	Badge,
}

// One kind of node: its name in JavaScript, its struct, whether it has children, and the level that added it.
Node_Declaration :: struct {
	kind:      Node_Kind,
	name:      string,
	props:     typeid,
	container: bool,
	level:     int,
}

NODES :: [?]Node_Declaration{
	{kind = .Text, name = "text", props = Text_Node, level = 2},
	{kind = .Heading, name = "heading", props = Heading_Node, level = 2},
	{kind = .Button, name = "button", props = Button_Node, level = 2},
	{kind = .Row, name = "row", props = Row_Node, container = true, level = 2},
	{kind = .Column, name = "column", props = Column_Node, container = true, level = 2},
	{kind = .Card, name = "card", props = Card_Node, container = true, level = 2},
	{kind = .Space, name = "space", props = Space_Node, level = 2},
	{kind = .Field, name = "field", props = Field_Node, level = 2},
	{kind = .Check, name = "check", props = Check_Node, level = 2},
	{kind = .Switch, name = "switch", props = Switch_Node, level = 2},
	{kind = .Separator, name = "separator", props = Separator_Node, level = 2},
	{kind = .List, name = "list", props = Lazy_List_Node, level = 5},
	{kind = .Badge, name = "badge", props = Badge_Node, level = 6},
}

////////////////////////////////
// Settings (level 3): the manifest's "settings" are the program's preferences, shown in its settings; the plugin reads
// them without waiting (the host gives its thread their values, and each change).

// A function of the plugin called with a setting's id and its new value.
Setting_Handler :: distinct js.Value

// The value of one of the manifest's settings: the person's, else its default. A boolean, a number or a string, as
// the setting's kind says.
Settings_Get :: struct {
	// The setting's id, as the manifest's `settings` declares it.
	id: string,
}

// Registers a function called after each change of one of the plugin's settings, in the settings or their file. The
// views are rendered again after it.
Settings_On_Change :: struct {
	handler: Setting_Handler,
}

////////////////////////////////
// Files, the network, the clipboard (level 4): each call is a request to the program's broker, which checks the grant
// and does the work on its workers; the promise settles with its answer. A path is one of: a relative path, in the
// plugin's own data folder (no permission); "~documents/..." or "~downloads/..." (their permission); an absolute path
// the person picked (files.pick). A path that leaves its folder (`..`) or goes through a link is refused.

// Reads a text file.
Files_Read :: struct {
	// Where it is.
	path: string,
}

// Writes a text file, its folders made when they are missing.
Files_Write :: struct {
	// Where it goes.
	path: string,
	// What it holds.
	text: string,
}

// What the system's dialog of files.pick offers.
Files_Pick_Options :: struct {
	// A folder, not a file.
	folder: bool `optional`,
	// The dialog's title.
	title:  string `optional`,
}

// Asks the person for a file or a folder in the system's dialog, while they act in the plugin. What they pick is
// granted until they revoke it in the Plugins page; null: they picked nothing.
Files_Pick :: struct {
	options: Files_Pick_Options `optional`,
}

// A request's options.
Fetch_Options :: struct {
	// "GET" when absent.
	method:      string `optional`,
	// The request's body, as text.
	body:        string `optional`,
	// Its Content-Type.
	contentType: string `optional`,
}

// An answer to http.fetch.
Fetch_Response :: struct {
	// Its HTTP status.
	status: int,
	// The address that answered, after the redirects.
	url:    string,
	// Its body, as text.
	text:   string,
}

// Asks an address of an origin the manifest names (or any public one with "net:*"). Each redirect is checked as the
// first address was: a hop to an origin not granted fails the call.
Http_Fetch :: struct {
	url:     string,
	options: Fetch_Options `optional`,
}

// Reads the clipboard's text, while the person acts in the plugin (a command, a click in its view).
Clipboard_Read :: struct {}

// Puts text on the clipboard.
Clipboard_Write :: struct {
	text: string,
}

////////////////////////////////
// Palette sources (level 7): a source the manifest declares ("palette"), answered by the plugin as the person types.

// A row of a palette source's answer.
Palette_Row :: struct {
	// Stable in its source: what the choice gives back.
	id:     string,
	// What the row says, and what the query lights.
	label:  string,
	// Weak, after the label (a folder, a time).
	detail: string `optional`,
	// A Lucide icon by its name.
	icon:   Icon_Name `optional`,
	// Its heading.
	group:  string `optional`,
}

// A function of the plugin called with what the person typed after the source's prefix; it returns the rows, or a
// promise of them (200 at most).
Palette_Search :: distinct js.Value

// A function of the plugin called with the row the person chose.
Palette_Choose_Handler :: distinct js.Value

// What a palette source does beside its search.
Palette_Source_Options :: struct {
	// Called with the row chosen.
	onChoose: Palette_Choose_Handler `optional`,
}

// Answers the palette source `id` of plugin.json's "palette": the program asks while the person types after its
// prefix, one question at a time (a newer query replaces one that waits).
Palette_Source_Call :: struct {
	id:      string,
	search:  Palette_Search,
	options: Palette_Source_Options `optional`,
}

// Gives the palette source `id` what choosing a row does (the same as palette.source's onChoose).
Palette_On_Choose :: struct {
	id:      string,
	handler: Palette_Choose_Handler,
}

// One call of the API.
Declaration :: struct {
	module:     string,     // the export of "gt" that holds it ("commands")
	name:       string,     // its name there ("on")
	arguments:  typeid,     // the struct of its arguments
	result:     Result,
	capability: Capability,
	level:      int,        // the level that added it
}

DECLARATIONS :: [?]Declaration{
	{module = "commands", name = "on", arguments = Commands_On, result = .Undefined, capability = .None, level = 1},
	{module = "toast", name = "show", arguments = Toast_Show, result = .Undefined, capability = .None, level = 1},
	{module = "views", name = "register", arguments = Views_Register, result = .Undefined, capability = .None, level = 2},
	{module = "views", name = "update", arguments = Views_Update, result = .Undefined, capability = .None, level = 2},
	{module = "settings", name = "get", arguments = Settings_Get, result = .Setting_Value, capability = .None, level = 3},
	{module = "settings", name = "onChange", arguments = Settings_On_Change, result = .Undefined, capability = .None, level = 3},
	{module = "files", name = "read", arguments = Files_Read, result = .Promise_Text, capability = .None, level = 4},
	{module = "files", name = "write", arguments = Files_Write, result = .Promise_Void, capability = .None, level = 4},
	{module = "files", name = "pick", arguments = Files_Pick, result = .Promise_Path, capability = .Files, level = 4},
	{module = "http", name = "fetch", arguments = Http_Fetch, result = .Promise_Response, capability = .Net, level = 4},
	{module = "clipboard", name = "read", arguments = Clipboard_Read, result = .Promise_Text, capability = .Clipboard_Read, level = 4},
	{module = "clipboard", name = "write", arguments = Clipboard_Write, result = .Promise_Void, capability = .Clipboard_Write, level = 4},
	{module = "palette", name = "source", arguments = Palette_Source_Call, result = .Undefined, capability = .None, level = 7},
	{module = "palette", name = "onChoose", arguments = Palette_On_Choose, result = .Undefined, capability = .None, level = 7},
}
