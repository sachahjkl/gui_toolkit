type: Fixed

**`prefs_page`**: a slider dragged and let go keeps its value. `ui.slider` moves its value only while the button is down, and the page read the preference again at the release: what was dragged was never written, and the slider went back. The page now keeps the value while the button is down and writes it when it comes up.
