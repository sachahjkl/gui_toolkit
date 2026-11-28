type: Fixed

**Tabs no longer waste side padding before truncating words.** `ui.tabs` and `ui.tabs_ex` previously combined a 1 em
spacer with the label's own `text_pad` on both sides (about 3 em of empty padding per tab). Tabs now use a single
tight side inset (0.45 em in dense strips such as the debug window, 0.7 em elsewhere) with `text_pad = 0`, leaving
more room for tab titles.
