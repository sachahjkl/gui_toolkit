type: Fixed

**A "+" whose tab comes later still fills its stack, and the views' words follow the language**: a stack's "+" now waits for the instance its `new_tab` asked for: the next one of that kind that opens within `ui.NEW_TAB_WAIT_MS` (10 s), even frames later (a shell a server makes), joins that stack as its last tab. `View_Options.new_tab_label` and the words a program gives `Views_Options.labels` are translated when shown, so a change of language during the session shows at once, as the titles already did.
