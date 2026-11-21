# File search (`gt:filesearch`)

`gt:filesearch` finds files and folders by name as the user types, with typo tolerance, background watching, and
frecency ranking backed by LMDB (`fff-search` in `native/filesearch`). A program that enables
`toolbox.Feature.Filesearch` links it in (`-define:GT_FILESEARCH=true`); without that define, `filesearch.available()`
is false and `filesearch.open` returns `.Unavailable`.

None of these calls belong on the interface thread: call `filesearch.open`, `filesearch.search`,
`filesearch.note_opened` and `filesearch.close` on a worker (such as `ui.task`) and post the page back.

```odin
import filesearch "gt:filesearch"

idx, err := filesearch.open({root = project_dir, frecency_dir = data_dir, watch = true})
if err == .None {
	defer filesearch.close(idx)
	_ = filesearch.wait_ready(idx, 5000)
	page, _ := filesearch.search(idx, "shcema", {limit = 50})
	defer filesearch.page_destroy(&page)
	for h in page.hits {
		// h.path (relative to root), h.dir, h.score, h.ranges (byte spans in h.path)
	}
	filesearch.note_opened(idx, "models/schema.odin")
}
```

| Symbol | What it does |
|---|---|
| `filesearch.available()` | true when built with `GT_FILESEARCH=true` |
| `filesearch.open(o)` | opens an `filesearch.Index` over `o.root` (`filesearch.Open_Options`), starting background scan and optional watcher |
| `filesearch.close(idx)` | stops the watcher and frees the index (safe on 0 or twice) |
| `filesearch.wait_ready(idx, timeout_ms)` | waits up to `timeout_ms` for the initial scan |
| `filesearch.state(idx)` | returns `filesearch.State` (`scanning`, `watching`, `scanned`) |
| `filesearch.search(idx, query, o, allocator)` | returns `filesearch.Page` of `filesearch.Hit` (with `filesearch.Match_Range` spans when `o.dirs == false`, or files + folders interleaved when `o.dirs == true`) |
| `filesearch.page_destroy(p, allocator)` | frees a `Page` returned by `search` |
| `filesearch.note_opened(idx, path)` | records a file open in the LMDB frecency store and updates the live index |

Design and platform measurements: [src/md/features/file-search.md](../src/md/features/file-search.md).
