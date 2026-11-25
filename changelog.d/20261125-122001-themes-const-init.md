type: Fixed

**`ui.THEMES` no longer emits an Odin large non-constant initializer warning**: Old Head's relief is assigned once at
startup so the 15 KiB theme table compiles as static data.
