type: Fixed

**The launcher check asks `--version`.** `toolbox.check_launcher` runs `<launcher> --version`, the form that `gt:cli` gives every program, instead of `version`, which a program that reads its line with `gt:cli` does not know.
