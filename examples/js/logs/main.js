// Log explorer, run by gt-runtime: `gt-runtime examples/js/logs`. A quarter of a million lines in a lazy list: the
// program asks only for the rows on screen. The search and the level switches filter every line in this plugin's own
// process, while the window stays fluid. Its commands are in the palette (Ctrl+K).
import { commands, palette, toast, views } from "gt";
import { COUNT, LEVELS, SERVICES, generate, filter, levelOf, message, clock, fmt } from "./lib/logs.js";

// How each level looks: its badge's tone and its icon (lucide.dev's names).
const LOOK = [
	{ tone: "info", icon: "info" },
	{ tone: "warn", icon: "alert-triangle" },
	{ tone: "bad", icon: "octagon-x" },
];

const data = generate();
let query = "";
let shown = [true, true, true];
let found = filter(data, query, shown);
let version = 1;   // the rows change with each filter: the list drops the ones it has
let open = -1;     // the line shown in detail

function refilter() {
	found = filter(data, query, shown);
	version += 1;
}

const badge = (level) => ({ kind: "badge", text: LEVELS[level].toUpperCase(), ...LOOK[level] });

function line(i) {
	const at = found.rows[i];
	return {
		kind: "row",
		children: [
			{ kind: "text", text: clock(data, at), mono: true, weak: true },
			badge(levelOf(data, at)),
			{ kind: "text", text: SERVICES[data.svc[at]], weak: true },
			{ kind: "text", text: message(data, at), highlight: query },
			{ kind: "space", size: "fill" },
			{ kind: "button", key: "open", label: "Open", icon: "panel-right-open", look: "ghost", size: "small", onClick: () => { open = at; } },
		],
	};
}

function render() {
	return {
		kind: "column",
		children: [
			{ kind: "heading", text: "Log explorer", icon: "scroll-text" },
			{
				kind: "row",
				key: "summary",
				children: [
					{ kind: "text", weak: true, text: `${fmt(found.rows.length)} of ${fmt(COUNT)} lines` },
					...LEVELS.map((name, level) => ({ ...badge(level), key: `count-${name}`, text: fmt(found.counts[level]) })),
				],
			},
			{
				kind: "row",
				key: "levels",
				children: LEVELS.map((name, level) => ({
					kind: "switch", key: `level-${name}`, label: name, icon: LOOK[level].icon, on: shown[level],
					onChange: (on) => { shown[level] = on; refilter(); },
				})),
			},
			{
				kind: "field", key: "query", value: query, icon: "search", placeholder: "Search every line: a word, a service, a number",
				onChange: (text) => { query = text; refilter(); },
			},
			open >= 0 && {
				kind: "card",
				key: "detail",
				title: `Line ${fmt(open + 1)}`,
				children: [
					{
						kind: "row",
						key: "detail-head",
						children: [
							badge(levelOf(data, open)),
							{ kind: "text", icon: "server", text: SERVICES[data.svc[open]], weak: true },
							{ kind: "text", icon: "clock-4", text: clock(data, open), mono: true, weak: true },
						],
					},
					{ kind: "text", key: "detail-message", text: message(data, open), highlight: query },
					{ kind: "button", key: "close", label: "Close", icon: "x", onClick: () => { open = -1; } },
				],
			},
			{ kind: "list", key: "lines", count: found.rows.length, version, rowHeight: 1.6, visibleRows: 14, row: line },
		],
	};
}

export function activate() {
	views.register("main", render);
	// "@" in the palette searches every line; choosing one opens it in the view
	palette.source("lines", (query) => filter(data, query, [true, true, true]).rows.slice(0, 200).map((at) => ({
		id: String(at), label: message(data, at), detail: `${LEVELS[levelOf(data, at)]} · ${SERVICES[data.svc[at]]} · ${clock(data, at)}`,
	})), { onChoose: (row) => { open = Number(row.id); views.update("main"); } });
	commands.on("errors", () => {
		shown = [false, false, true];
		refilter();
		views.update("main");
		toast.show(`${fmt(found.rows.length)} errors`, { kind: "bad" });
	});
	commands.on("everything", () => {
		query = "";
		shown = [true, true, true];
		refilter();
		views.update("main");
	});
	commands.on("newest", () => {
		for (let i = COUNT - 1; i >= 0; i--) {
			if (levelOf(data, i) === 2) { open = i; break; }
		}
		views.update("main");
	});
}
