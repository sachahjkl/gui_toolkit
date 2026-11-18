// The module "gt" of a plugin, level 2. Made by `odin run tools/tk -- plugin_api` from src/plugin_api/api.odin: do not edit.
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

	/** What a button's colour says. */
	export type Button_Intent = "neutral" | "primary" | "success" | "warning" | "danger";

	/** How a button sits: `raised` has a face of its own; `ghost` none until the pointer is over it (an act repeated in each row of a list); `link` reads as a link. */
	export type Button_Look = "raised" | "ghost" | "link";

	/** A button's size, all its measures together; `small` for an act in each row of a list, `large` for the one act of a view. */
	export type Button_Size = "medium" | "small" | "large";

	/** A step of the toolkit's spacing scale; `fill` takes the room left in a row. */
	export type Space_Size = "small" | "medium" | "large" | "fill";

	/** A paragraph of text; it wraps in a column. */
	export interface Text_Node {
		kind: "text";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		text: string;
		/** Drawn in the weak colour. */
		weak?: boolean;
	}

	/** A title of a part of the view. */
	export interface Heading_Node {
		kind: "heading";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		text: string;
	}

	/** A button. */
	export interface Button_Node {
		kind: "button";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		label: string;
		intent?: Button_Intent;
		/** How it sits and its size. A program older than these fields shows a raised, medium button. */
		look?: Button_Look;
		size?: Button_Size;
		disabled?: boolean;
		/** Called when it is pressed. */
		onClick?: () => void | Promise<void>;
	}

	/** Its children side by side. */
	export interface Row_Node {
		kind: "row";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		children?: (Node | null | undefined | false)[];
	}

	/** Its children one under the other. */
	export interface Column_Node {
		kind: "column";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		children?: (Node | null | undefined | false)[];
	}

	/** A titled panel around its children, as wide as the view. */
	export interface Card_Node {
		kind: "card";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		title?: string;
		children?: (Node | null | undefined | false)[];
	}

	/** Room between two nodes ("small" when absent). */
	export interface Space_Node {
		kind: "space";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		size?: Space_Size;
	}

	/** A line of text the person types. The host keeps what is typed: a value the plugin gives is shown unless the person typed since the plugin last heard of it. Without a value, the field keeps its own text. */
	export interface Field_Node {
		kind: "field";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		value?: string;
		placeholder?: string;
		/** Called with the text at each change. */
		onChange?: (value: string) => void | Promise<void>;
		/** Called with the text when Enter is pressed. */
		onSubmit?: (value: string) => void | Promise<void>;
	}

	/** A check box and its words. */
	export interface Check_Node {
		kind: "check";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		label: string;
		checked?: boolean;
		/** Called with its new state when the person changes it. */
		onChange?: (value: boolean) => void | Promise<void>;
	}

	/** A switch and its words. */
	export interface Switch_Node {
		kind: "switch";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
		label: string;
		on?: boolean;
		/** Called with its new state when the person changes it. */
		onChange?: (value: boolean) => void | Promise<void>;
	}

	/** A line across the view. */
	export interface Separator_Node {
		kind: "separator";
		/** Unique in the view: what the host knows the node by between two renders. */
		key?: string | number;
	}

	/** A node of a view: what a render returns, and a container's children. */
	export type Node = Text_Node | Heading_Node | Button_Node | Row_Node | Column_Node | Card_Node | Space_Node | Field_Node | Check_Node | Switch_Node | Separator_Node;

	export const commands: {
		/** Registers the handler of one of the manifest's commands: choosing the command in the palette calls it. A second call for the same command replaces the handler. (level 1) */
		on(id: string, handler: () => void | Promise<void>): void;
	};

	export const toast: {
		/** Shows a message to the person: a toast of the window, or the system's notification when the program says its messages there. (level 1) */
		show(text: string, options?: Toast_Options): void;
	};

	export const views: {
		/** Registers the render of one of the manifest's views. A second call for the same view replaces it. (level 2) */
		register(id: string, render: () => Node): void;
		/** Asks for the view's render again, after the current handler: the plugin's state changed outside a handler of the view (a command, a promise that settled). (level 2) */
		update(id: string): void;
	};

}
