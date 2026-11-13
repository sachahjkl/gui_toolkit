type: Added

**A Diagnostics page in the settings, with a Copy button.** It says the program's and the toolkit's versions, the system, the graphics adapter and API (and warns when a software rasterizer draws), the window's size and scale, the last frames' build and draw times (median and 95th percentile) and the share of pixels partial redraw drew: what a person on a slow machine sends. Every host keeps its last pictures' times in every build (`host.Frame_Ring`, `host.frame_stats`); `render.adapter_info` names the adapter (docs/prefs_page.md, docs/rendering.md).
