type: Added

**`fsx.path_join`, `fsx.safe_file_name`, `base.read_be16` and `base.read_be32`**: a program joins a name to a folder by
its system's separator or a given one, turns a person's name for a thing into a file name that every system accepts,
and reads big-endian integers without a panic past the end. `ui.file_path_join` is gone: call `fsx.path_join(dir, name,
sep)`. A licence file's name is made by `safe_file_name` too: an order number with other characters than letters,
digits, `_` and `-` now keeps them where a system allows them.
