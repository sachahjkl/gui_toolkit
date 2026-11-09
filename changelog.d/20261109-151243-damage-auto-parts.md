type: Changed

**`draw.damage_auto`** works out the region in linear time: 0.45 ms instead of 2.0 to 2.6 ms for 10,000 spans (`-o:speed`). A span is compared by parts (what it drew between two children); `Damage_Memory` holds `parts` and `next` (swapped, not copied), `Damage_Span` is now `Damage_Part`, `Damage_Auto_Stats` has `parts` (was `spans`), `ms`, `px_drawn` and `px_window`, and `Damage_Whole.Offscreen` is now `Plane`. A second memory in one frame asserts.
