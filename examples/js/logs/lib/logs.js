// A quarter of a million log lines, made from a fixed seed: the same lines at each run. They are kept in typed arrays,
// a few bytes a line; a line's words are made only when its row is shown.

export const COUNT = 250000;
export const LEVELS = ["info", "warn", "error"];
export const SERVICES = ["api", "auth", "billing", "search", "storage", "mailer"];

// What a line says, by level; "#" is the line's number (a time, an id, a count).
const TEMPLATES = [
	[0, "GET /v1/items/# 200"], [0, "user # signed in"], [0, "cache warmed: # keys"], [0, "job # done"],
	[0, "POST /v1/orders 201 in # ms"], [0, "session # renewed"], [0, "index rebuilt: # documents"],
	[1, "slow query: # ms"], [1, "retry # of 5 for upstream"], [1, "disk at #% of its quota"],
	[1, "rate limit near for client #"], [1, "certificate expires in # days"],
	[2, "timeout after # ms talking to db"], [2, "payment # declined"], [2, "connection reset by peer #"],
	[2, "worker # crashed"], [2, "queue full: # jobs dropped"],
];
const LEVEL_OF = Uint8Array.from(TEMPLATES, ([level]) => level);
const BY_LEVEL = LEVELS.map((_, level) => TEMPLATES.flatMap(([l], t) => (l === level ? [t] : [])));

// A small, fast generator of numbers in [0, 1) (mulberry32): a seed gives the same lines everywhere.
function generator(seed) {
	let s = seed >>> 0;
	return () => {
		s = (s + 0x6d2b79f5) >>> 0;
		let t = s;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

export function generate(seed = 7) {
	const rand = generator(seed);
	const data = {
		time: new Uint32Array(COUNT), tpl: new Uint8Array(COUNT),
		svc: new Uint8Array(COUNT), param: new Uint32Array(COUNT),
	};
	let t = 9 * 3600;
	for (let i = 0; i < COUNT; i++) {
		t += Math.floor(rand() * 3);
		const r = rand();
		const choices = BY_LEVEL[r < 0.86 ? 0 : r < 0.97 ? 1 : 2];
		data.time[i] = t;
		data.tpl[i] = choices[Math.floor(rand() * choices.length)];
		data.svc[i] = Math.floor(rand() * SERVICES.length);
		data.param[i] = 10 + Math.floor(rand() * 9000);
	}
	return data;
}

export const levelOf = (data, i) => LEVEL_OF[data.tpl[i]];
export const message = (data, i) => TEMPLATES[data.tpl[i]][1].replace("#", String(data.param[i]));

export function clock(data, i) {
	const s = data.time[i] % 86400;
	const two = (n) => String(n).padStart(2, "0");
	return `${two(Math.floor(s / 3600))}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}`;
}

// 12345 -> "12 345".
export const fmt = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, " ");

// The lines that match `query` (a word of the message, a service, or a number) and whose level is shown: their
// indexes, and the count of each level among the matches. The words are matched once per kind of line, not per line,
// so a search of every line stays a pass over a few arrays of numbers.
export function filter(data, query, shown) {
	const q = query.trim().toLowerCase();
	const byTemplate = TEMPLATES.map(([, words]) => q === "" || words.toLowerCase().includes(q));
	const byService = SERVICES.map((name) => q !== "" && name.includes(q));
	const numeric = /^\d+$/.test(q);
	const rows = new Int32Array(COUNT);
	const counts = [0, 0, 0];
	let n = 0;
	for (let i = 0; i < COUNT; i++) {
		const t = data.tpl[i];
		const hit = byTemplate[t] || byService[data.svc[i]] || (numeric && String(data.param[i]).includes(q));
		if (!hit) continue;
		const level = LEVEL_OF[t];
		counts[level] += 1;
		if (shown[level]) rows[n++] = i;
	}
	return { rows: rows.subarray(0, n), counts };
}
