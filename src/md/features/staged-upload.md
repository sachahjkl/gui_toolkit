# A large picture's upload over several frames (`render.Upload`)

galerie shows a 50-megapixel photo whole: 200 MB of RGBA, then its mips. The upload ran in one frame on the interface's
thread: the premultiplication (a pass over every pixel on the CPU), the copy into the driver's staging memory, then the
mips. Measured on the software device (lavapipe, `-o:speed`), a 7000 x 7000 picture (186 MB): 84 to 140 ms in one call.

## Decisions

- **Spread over frames, on every backend: a band of rows at a time within a time budget.** `upload_step` writes bands
  of 1 MiB until 2 ms are spent, one at least, so an upload always moves and no frame holds more than the budget and a
  band. The same picture: 15 to 19 frames, the worst 2.7 ms, 34 to 39 ms in all (less than the one call: no 186 MB
  staging allocation at once). It uses only `update_texture_rgba` of a rectangle, which both backends have, so it is
  one code path and the test covers both.
- **The mips once, after the last band.** Each band marks the texture's mips dirty, and the frame makes them again; the
  upload clears the mark after every band but the last, so the chain is made once from the whole picture.
- **No zeroing on Direct3D.** A texture never written is zeroed before its first draw (`Texture_Data.unfilled`), a
  whole upload of zeros in one frame. The staged upload promises every row before a draw, so it clears the mark.
- **One budget a frame for the whole cache: only `frame` steps.** The first version also stepped an upload when its
  decode answered, with a budget of its own: the answers that arrive at one build (a folder opened, five photos) each
  spent a budget, then `frame` one more. An answer only queues its upload; `frame`, in the same build, steps every
  queued upload within one budget. Two caches have two budgets: a program has one.
- **A recovered device starts the bands again.** A device lost and recreated gives back the texture empty; the
  upload compares `device_generation` at each step and starts again from row 0 (no zeroing), so the picture made Ready
  never has the top bands of a device that is gone.
- **The picture is Pending until its last band.** A half-uploaded picture is never drawn; `gt:pictures` keeps its
  pixels meanwhile and counts its bytes in the budget only once Ready. A picture dropped while it uploads gives its
  texture to the next frame's destroy and its pixels back at once.

## What each backend could do off the interface's thread

- **Direct3D 11.** The device is free-threaded (the renderer never asks for `SINGLETHREADED`): `CreateTexture2D` with
  its pixels as initial data (`D3D11_SUBRESOURCE_DATA`) may run on the decode's worker, and the upload leaves the
  interface's thread entirely; only `GenerateMips` needs the immediate context (a GPU command, no CPU pass). The
  renderer's texture table is the interface's thread's, so the worker would hand back the `ID3D11Texture2D` and its
  view to be registered. Deferred contexts were refused: drivers often emulate them (a copy anyway), and
  `UpdateSubresource` on one has a documented driver workaround.
- **WebGPU (wgpu-native, Vulkan).** The device and the queue are thread-safe: `wgpuQueueWriteTexture` from a worker
  copies into wgpu's staging memory at once and the copy runs before the next submit. The texture would be made on
  the interface's thread (its slot in the table) and its `wgpu.Texture` handle, with a reference added, given to the
  worker with the premultiplication. On wgpu's GL fallback the call is accepted but the GL context's thread does the
  work.
- **Why spread first.** It needs nothing of either backend's threading, keeps the renderer's tables on one thread, and
  bounds every frame now. Moving the copy and the premultiplication to the decode worker is the next step
  (ROADMAP, "A picture's upload off the interface's thread"): it removes the 2 ms a frame too.

## The test that breaks it

`tests/pictures`, `a_large_picture_is_uploaded_over_several_frames`: a budget of nothing writes one band a frame; the
picture must stay Pending over several frames, then be drawn with its lower half (the last bands) in place.
`large_answers_of_one_build_share_its_upload_budget`: two answers at one build write one band in all at that build; a
`device_generation` bumped mid-upload sends the next step back to the first band.
