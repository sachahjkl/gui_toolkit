type: Added

**Builds without the fallback fonts**: `-define:FONT_EMBED_FALLBACK=false` leaves Roboto and Inconsolata out of the executable (244 KB), for a program that loads its fonts itself; `font.FALLBACK_UI_DATA` and `font.FALLBACK_MONO_DATA` are then empty.
