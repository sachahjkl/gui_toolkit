// The module "gt" of a plugin, level 1. Made by `odin run tools/tk -- plugin_api` from src/plugin_api/api.odin: do not edit.
declare module "gt" {
	/** How a toast looks. */
	export type Toast_Kind = "info" | "good" | "warn" | "bad";

	/** A toast's options. */
	export interface Toast_Options {
		/** Its look ("info" when absent). */
		kind?: Toast_Kind;
		/** A line in bold above the text. */
		title?: string;
	}

	/** What the entry file's activate(context) is given (gt:plugins makes it: plugins/runtime.odin, context_object). */
	export interface Activate_Context {
		/** The plugin's id, as plugin.json says it. */
		id: string;
		/** Its name. */
		name: string;
		/** Its version ("" when plugin.json says none). */
		version: string;
		/** The level of the API this program gives. */
		api: number;
	}

	export const commands: {
		/** Registers the handler of one of the manifest's commands: choosing the command in the palette calls it. A second call for the same command replaces the handler. (level 1) */
		on(id: string, handler: () => void | Promise<void>): void;
	};

	export const toast: {
		/** Shows a message to the person: a toast of the window, or the system's notification when the program says its messages there. (level 1) */
		show(text: string, options?: Toast_Options): void;
	};

}
