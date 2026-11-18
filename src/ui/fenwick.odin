package ui

import "core:slice"

// A Fenwick tree (binary indexed tree) over n values: a value changed, the sum of the first i values, and the place
// where those sums pass a bound, each in O(log n). The find bar counts its matches with one (find.odin) and a virtual
// list places its rows with one (vlist.odin): both have rows by the million and change a few of them per build, so
// neither can afford a pass over all the rows in a build.
//
// `T` is any type with `+` and `-`: a number, or a fixed array (a virtual list keeps [2]f64, a height and a count).
// The tree is 1-based: tree[0] is not used, and value i (0-based) is under node i + 1.

@(private)
Fenwick :: struct($T: typeid) {
	tree: [dynamic]T,
}

@(private)
fenwick_destroy :: proc(f: ^Fenwick($T)) {
	delete(f.tree)
}

// The values in the tree.
@(private)
fenwick_len :: proc(f: ^Fenwick($T)) -> int {
	return max(len(f.tree) - 1, 0)
}

// n values, all zero.
@(private)
fenwick_reset :: proc(f: ^Fenwick($T), n: int) {
	resize(&f.tree, n + 1)
	slice.zero(f.tree[:])
}

@(private)
fenwick_clear :: proc(f: ^Fenwick($T)) {
	clear(&f.tree)
}

// Every value zero again, the count kept.
@(private)
fenwick_zero :: proc(f: ^Fenwick($T)) {
	slice.zero(f.tree[:])
}

// n values made at once, in O(n) (n point updates would be O(n log n)): the caller writes value i in leaves[i],
// then calls fenwick_build.
@(private)
fenwick_leaves :: proc(f: ^Fenwick($T), n: int) -> (leaves: []T) {
	resize(&f.tree, n + 1)
	slice.zero(f.tree[:1])
	return f.tree[1:]
}

// The leaves written by fenwick_leaves, made a tree: each node adds itself to its parent, in order.
@(private)
fenwick_build :: proc(f: ^Fenwick($T)) {
	n := len(f.tree) - 1
	for p in 1 ..= n {
		q := p + (p & -p)
		if q <= n { f.tree[q] += f.tree[p] }
	}
}

// Value i gets `d` added.
@(private)
fenwick_add :: proc(f: ^Fenwick($T), i: int, d: T) {
	for p := i + 1; p < len(f.tree); p += p & -p { f.tree[p] += d }
}

// The sum of values [0, i) (i past the end: all of them).
@(private)
fenwick_sum :: proc(f: ^Fenwick($T), i: int) -> (sum: T) {
	for p := min(i, len(f.tree) - 1); p > 0; p -= p & -p { sum += f.tree[p] }
	return
}

// Value i alone, in O(log n) and without two sums: node i + 1 less the nodes under it.
@(private)
fenwick_get :: proc(f: ^Fenwick($T), i: int) -> (v: T) {
	p := i + 1
	if i < 0 || p >= len(f.tree) { return }
	v = f.tree[p]
	stop := p - (p & -p)
	for q := p - 1; q > stop; q -= q & -q { v -= f.tree[q] }
	return
}

// The most values [0, p) whose sum is <= `limit` (values >= 0: the sums only grow). The row that holds the k-th
// match is p, for k = limit.
@(private)
fenwick_find :: proc(f: ^Fenwick($T), limit: T) -> int {
	pos, rest := 0, limit
	step := 1
	for step * 2 < len(f.tree) { step *= 2 }
	for ; step > 0; step /= 2 {
		if pos + step < len(f.tree) && f.tree[pos + step] <= rest {
			pos += step
			rest -= f.tree[pos]
		}
	}
	return pos
}

// fenwick_find for values that are not numbers: `weigh` gives what a node of `span` values counts for (a virtual
// list's node is its measured heights and the estimate times the rows not measured), with `arg` passed through
// (no closures in Odin). The weights must be >= 0.
@(private)
fenwick_find_by :: proc(f: ^Fenwick($T), limit: $W, weigh: proc(node: T, span: int, arg: W) -> W, arg: W) -> int {
	pos, rest := 0, limit
	step := 1
	for step * 2 < len(f.tree) { step *= 2 }
	for ; step > 0; step /= 2 {
		if pos + step >= len(f.tree) { continue }
		w := weigh(f.tree[pos + step], step, arg)
		if w <= rest {
			pos += step
			rest -= w
		}
	}
	return pos
}
