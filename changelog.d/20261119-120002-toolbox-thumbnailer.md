type: Added

**`toolbox.Project.thumbnailer`**: the package of a program's thumbnail provider. On Windows `build_native` builds it last as `thumbnailer_path(p)` (`<name>_thumbnails.dll`, optimised for a release: `build_native(p, release)`), every odin command of the program embeds it (`-define:GT_THUMBNAIL_DLL=<file>`), and `check_windows` checks it.
