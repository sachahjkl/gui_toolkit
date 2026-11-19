# shell_thumbnail: thumbnails in Windows Explorer

`import shell_thumbnail "gt:shell_thumbnail"`. A program's own thumbnail provider for Explorer: Explorer shows the
program's documents (a PDF's first page) as thumbnails that the program draws. Explorer loads a thumbnail provider
only from an in-process COM DLL, so the program has a small DLL of its own. This package does its COM plumbing; the
program gives the render. The reasons are in
[src/md/features/shell-thumbnails.md](../src/md/features/shell-thumbnails.md).

The whole chain:

1. The program's DLL package (below) calls `set` with its CLSID and its render.
2. `gt:toolbox` builds it as a DLL when the `Project` names it (`thumbnailer`: the folder of that package, in the program's tree), before the
   program, and the program embeds it ([toolbox.md](toolbox.md)).
3. The program's install writes it beside the executable and registers it: the Thumbnails part of `gt:desktop`
   ([desktop.md](desktop.md#thumbnails-in-the-file-managers)).

## The program's DLL package

```odin
package thumbnailer

import shell_thumbnail "gt:shell_thumbnail"

// The program's own CLSID: made once (any GUID generator), never changed. The install registers the same string.
CLSID :: "{0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b}"

@(init)
thumbnailer_init :: proc "contextless" () { shell_thumbnail.set(CLSID, render) }

// The first page fitted in size x size, straight RGBA8, in context.allocator (the package frees it).
render :: proc(data: []u8, size: int) -> (rgba: []u8, width, height: int, ok: bool) {
	...
}

@(export, link_name = "DllGetClassObject")
DllGetClassObject :: proc "system" (rclsid, riid: ^shell_thumbnail.GUID, ppv: ^rawptr) -> shell_thumbnail.HRESULT {
	return shell_thumbnail.dll_get_class_object(rclsid, riid, ppv)
}

@(export, link_name = "DllCanUnloadNow")
DllCanUnloadNow :: proc "system" () -> shell_thumbnail.HRESULT { return shell_thumbnail.dll_can_unload_now() }
```

Odin's runtime gives the DLL its `DllMain`, which runs the `@(init)` procedures. They run under the system's loader
lock: keep them to `set`. A package the DLL imports runs its own `@(init)` there too.

## What it has

| | |
|---|---|
| `set(clsid, render)` | the CLSID the DLL serves (`"{8-4-4-4-12}"`) and the program's render; a malformed CLSID serves nothing |
| `Render` | `proc(data: []u8, size: int) -> (rgba: []u8, width, height: int, ok: bool)`: `data` is the whole document, borrowed for the call; the picture fits in `size` x `size`; `rgba` in `context.allocator` |
| `dll_get_class_object(rclsid, riid, ppv)` | the class factory of the CLSID given to `set`, else `CLASS_E_CLASSNOTAVAILABLE` |
| `dll_can_unload_now()` | `S_OK` when no object and no lock is left, else `S_FALSE` |
| `guid_parse(s)` | a registry string's GUID, as Windows lays it out |
| `bgra_on_white(rgba, bgra)` | straight RGBA8 to opaque BGRA, composited on white (what the provider gives the shell) |
| `DOCUMENT_MAX` | 256 MB: a larger document is refused before it is read |

## What the provider does

- `IInitializeWithStream::Initialize` reads the whole stream into memory (the size from `Stat` first). A document
  larger than `DOCUMENT_MAX` is refused (`E_FAIL`).
- `IThumbnailProvider::GetThumbnail(cx)` calls the render with `cx`, then makes a top-down 32-bit DIB section: BGRA,
  every pixel opaque on white, `WTSAT_RGB`. A failed render gives `E_FAIL`: Explorer shows the type's icon.
- Each COM entry makes its own Odin context (`runtime.default_context()`), and frees its temporary memory after the
  call.

## The render runs on several threads

Explorer runs the provider in a surrogate process (`dllhost.exe`), which may ask several thumbnails at once on
several threads. The render must be thread-safe: `gt:pdf` is. A render that panics ends the surrogate, never
Explorer.

On other systems the package compiles: `set` keeps its values, `dll_get_class_object` refuses. Linux's file managers
run the program itself ([desktop.md](desktop.md#thumbnails-in-the-file-managers)).
