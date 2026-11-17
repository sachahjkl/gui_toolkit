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
PLUGIN_API_LEVEL :: 3
PLUGIN_API_OLDEST :: 1

// What a call needs the person to have granted. `.None`: nothing (a call the realm may always make).
Capability :: enum u8 {
	None,
}

// What a call gives back to JavaScript.
Result :: enum u8 {
	Undefined,
	Setting_Value,   // a boolean, a number or a string: what the implementation returns
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

// A step of the toolkit's spacing scale; `fill` takes the room left in a row.
Space_Size :: enum u8 {
	small,
	medium,
	large,
	fill,
}

// A paragraph of text; it wraps in a column.
Text_Node :: struct {
	text: string,
	// Drawn in the weak colour.
	weak: bool `optional`,
}

// A title of a part of the view.
Heading_Node :: struct {
	text: string,
}

// A button.
Button_Node :: struct {
	label:    string,
	intent:   Button_Intent `optional`,
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
	// Called with its new state when the person changes it.
	onChange: Flag_Handler `optional`,
}

// A line across the view.
Separator_Node :: struct {}

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
}
