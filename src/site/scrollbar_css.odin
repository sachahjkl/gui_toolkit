package tk_site

// The scroll bar of the toolkit's windows on every page of a site (src/md/features/scroll-bar.md): the thin bar, 9 px, a
// trough with its gradient across the bar, a thumb with its border, its four stops and its inner line, an arrow button
// at each end, the accent while the pointer is over the thumb and deeper while it is held. Its colours are mixed from
// the site's own custom properties, as the toolkit mixes them from the theme's surfaces (scrollbar_colors, the dark
// table), so each site keeps its accent. Chromium and Safari draw all of it (::-webkit-scrollbar); Firefox takes the
// two colours it knows (scrollbar-color), as a browser that draws its own bar can.
SCROLLBAR_CSS :: `<style>
:root {
  --gt-sb-track: var(--bg2, var(--surface, #161616));
  --gt-sb-line: var(--line, var(--line-2, #3a3a3a));
  --gt-sb-weak: var(--weak, var(--muted, #8a8a8a));
  --gt-sb-text: var(--text, #e6e6e6);
  --gt-sb-accent: var(--accent, #6f9cf0);
  --gt-sb-edge: color-mix(in srgb, var(--gt-sb-track), var(--gt-sb-line));
}
@supports (-moz-appearance: none) {
  html { scrollbar-width: thin; scrollbar-color: color-mix(in srgb, var(--gt-sb-line) 76%, var(--gt-sb-weak)) var(--gt-sb-edge); }
}
::-webkit-scrollbar { width: 9px; height: 9px; }
::-webkit-scrollbar-corner { background: var(--gt-sb-edge); }
::-webkit-scrollbar-track:vertical { background: linear-gradient(to right, var(--gt-sb-edge), var(--gt-sb-line), var(--gt-sb-edge)); }
::-webkit-scrollbar-track:horizontal { background: linear-gradient(to bottom, var(--gt-sb-edge), var(--gt-sb-line), var(--gt-sb-edge)); }
::-webkit-scrollbar-thumb {
  border: 1px solid color-mix(in srgb, var(--gt-sb-line) 60%, var(--gt-sb-weak)); border-radius: 3px;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.12); min-height: 20px; min-width: 20px;
}
::-webkit-scrollbar-thumb:vertical { background: linear-gradient(to right,
  color-mix(in srgb, var(--gt-sb-line) 70%, var(--gt-sb-weak)), color-mix(in srgb, var(--gt-sb-line) 76%, var(--gt-sb-weak)) 45%,
  color-mix(in srgb, var(--gt-sb-line) 82%, var(--gt-sb-weak)) 55%, color-mix(in srgb, var(--gt-sb-line) 88%, var(--gt-sb-weak))); }
::-webkit-scrollbar-thumb:horizontal { background: linear-gradient(to bottom,
  color-mix(in srgb, var(--gt-sb-line) 70%, var(--gt-sb-weak)), color-mix(in srgb, var(--gt-sb-line) 76%, var(--gt-sb-weak)) 45%,
  color-mix(in srgb, var(--gt-sb-line) 82%, var(--gt-sb-weak)) 55%, color-mix(in srgb, var(--gt-sb-line) 88%, var(--gt-sb-weak))); }
::-webkit-scrollbar-thumb:hover { border-color: var(--gt-sb-accent); background: linear-gradient(to right,
  color-mix(in srgb, var(--gt-sb-track) 55%, var(--gt-sb-accent)), color-mix(in srgb, var(--gt-sb-track) 62%, var(--gt-sb-accent)) 45%,
  color-mix(in srgb, var(--gt-sb-track) 69%, var(--gt-sb-accent)) 55%, color-mix(in srgb, var(--gt-sb-track) 76%, var(--gt-sb-accent))); }
::-webkit-scrollbar-thumb:active { border-color: var(--gt-sb-accent); background: linear-gradient(to right,
  color-mix(in srgb, var(--gt-sb-track) 42%, var(--gt-sb-accent)), color-mix(in srgb, var(--gt-sb-track) 50%, var(--gt-sb-accent)) 45%,
  color-mix(in srgb, var(--gt-sb-track) 58%, var(--gt-sb-accent)) 55%, color-mix(in srgb, var(--gt-sb-track) 66%, var(--gt-sb-accent))); }
/* the arrow buttons: a triangle of the weak text, the accent's under the pointer */
::-webkit-scrollbar-button:single-button { display: block; width: 9px; height: 9px; background-color: var(--gt-sb-edge);
  background-repeat: no-repeat; background-position: center; background-size: 5px 3px; }
::-webkit-scrollbar-button:single-button:vertical:decrement { background-image: conic-gradient(from 135deg at 50% 0, color-mix(in srgb, var(--gt-sb-weak) 70%, var(--gt-sb-text)) 90deg, transparent 0); }
::-webkit-scrollbar-button:single-button:vertical:increment { background-image: conic-gradient(from -45deg at 50% 100%, color-mix(in srgb, var(--gt-sb-weak) 70%, var(--gt-sb-text)) 90deg, transparent 0); }
::-webkit-scrollbar-button:single-button:horizontal:decrement { background-size: 3px 5px; background-image: conic-gradient(from 45deg at 0 50%, color-mix(in srgb, var(--gt-sb-weak) 70%, var(--gt-sb-text)) 90deg, transparent 0); }
::-webkit-scrollbar-button:single-button:horizontal:increment { background-size: 3px 5px; background-image: conic-gradient(from 225deg at 100% 50%, color-mix(in srgb, var(--gt-sb-weak) 70%, var(--gt-sb-text)) 90deg, transparent 0); }
::-webkit-scrollbar-button:single-button:hover { background-color: color-mix(in srgb, var(--gt-sb-track) 72%, var(--gt-sb-accent)); }
::-webkit-scrollbar-button:single-button:active { background-color: color-mix(in srgb, var(--gt-sb-track) 60%, var(--gt-sb-accent)); }
</style>`
