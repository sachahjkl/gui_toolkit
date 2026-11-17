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
PLUGIN_API_LEVEL :: 1
PLUGIN_API_OLDEST :: 1

// What a call needs the person to have granted. `.None`: nothing (a call the realm may always make).
Capability :: enum u8 {
	None,
}

// What a call gives back to JavaScript.
Result :: enum u8 {
	Undefined,
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
}
