type: Changed

**WebP inside the program.** A program that reads and writes WebP pictures is standalone on every system: no `gt_webp.dll` beside it on Windows, no system libwebp on Linux; a program with `toolbox.Feature.Webp` builds libwebp into `gt_native` (`tk build_native`, part `webp`) and builds with `-define:IMAGE_WEBP=true`. `tk build_webp` and `desktop.TOOLKIT_FILES` are gone.
