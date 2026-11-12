type: Added

**`desktop.thumbnail`**: the system's thumbnail of a file (a PDF's page, a video's frame, a document), for a worker: on Linux the freedesktop.org cache in `~/.cache/thumbnails` and the thumbnailers of the desktop (made on a miss, kept in the cache, failures remembered), on Windows the shell's (`IShellItemImageFactory`). `thumbnail_cached` reads the cache only; `thumbnail_store` keeps a program's own picture in it (Linux).
