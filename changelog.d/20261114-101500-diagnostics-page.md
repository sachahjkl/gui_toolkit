type: Added

**A Diagnostics page in the settings, with a Copy button** (docs/prefs_page.md, docs/rendering.md). It says the program's and the toolkit's versions, the system, the graphics adapter and API (with a warning when a software rasterizer draws), the window's size and scale, the last frames' build and draw times (median and 95th percentile) and the share of pixels that partial redraw drew: what a person on a slow machine sends. Every host keeps its last frames' times in every build (`host.Frame_Ring`, `host.frame_stats`); `render.adapter_info` names the adapter.
