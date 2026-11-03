type: Added

**`ui.set_scrollbar_arrows`**: classic arrow buttons at both ends of the scroll bars of scroll boxes, off by default (the bars stay as they were): each as long as the bar is broad, taken from the track; a press scrolls a step (3 em, eased like the wheel), held it repeats after 250 ms every 50 ms while the pointer stays on it. `ui.scrollbar_arrow_rects` gives where they are; **`draw.triangle`** fills a triangle in one-pixel rows (the arrows' glyph). Test arrow_buttons_step_and_repeat
