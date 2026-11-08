type: Fixed

**System fonts on Linux take fontconfig's aliases and generic families**: `font.load_system` and `font.has_system_family` give "Courier New" the installed font the configuration binds to it (Liberation Mono, by 30-metric-aliases.conf), and `monospace`, `serif`, `sans-serif` and the other generic families the font fontconfig picks. They refused any answer whose family was not the one asked for, so such a name was missing and text fell to the next font.
