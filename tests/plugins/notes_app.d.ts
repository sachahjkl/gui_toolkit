// The module "app" of Notes test, level 1. Made from its declaration by plugin_api.app_module_dts: do not edit.
declare module "app" {
	export interface Notes_List {
	}

	export interface Notes_List_Result {
		/** The notes, oldest first */
		items: Note[];
	}

	export interface Note {
		/** Its id, unique in the program */
		id: number;
		/** Its title */
		title: string;
	}

	export interface Notes_Add {
		/** The new note's title */
		title: string;
	}

	export interface Notes_Add_Result {
		/** The new note's id */
		id: number;
	}

	export interface Note_Added {
		/** The note added */
		note: Note;
	}

	export const notes: {
		/** The notes, oldest first. */
		list(args?: Notes_List): Promise<Notes_List_Result>;
		/** Adds a note, answered once it is kept. (needs the permission app:notes.write) */
		add(args: Notes_Add): Promise<Notes_Add_Result>;
	};

	/** A note was added. */
	export function on(event: "note.added", handler: (payload: Note_Added) => void | Promise<void>): void;
}
