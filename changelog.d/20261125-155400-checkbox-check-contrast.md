type: Fixed

**`ui.checkbox` checkmark contrast and Ember Light accent**: checkmarks now use the theme's `accent_text` (falling back to `ui.ink_on` to keep WCAG AA contrast >= 4.5:1) instead of hardcoded white, fixing unreadable checks on bright dark-theme accents; Ember Light's accent deepens to `#b8521d` so light ink reads at >= 4.5:1 WCAG AA on it.
