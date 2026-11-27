# A frame larger than one buffer

A frame of any size is drawn or, past what a device can bind at all, partly drawn. It never ends the process.

## What aborted

plume selected a line of 52 MB: one rectangle per row of the wrapped line, 2.87 million instances, 413,634,096 bytes in
one instance buffer. WebGPU's default `maxBufferSize` is 256 MiB. `wgpuDeviceCreateBuffer` gave an invalid buffer (an
error to `uncaptured_error`), the render pass that bound it was invalid, and `wgpuQueueSubmit` of invalid commands is a
`handle_error_fatal` in wgpu-native: a Rust panic through the C ABI, an abort ([no-graphics.md](no-graphics.md) has the
mechanism). Direct3D 11 did not abort but drew nothing: `CreateBuffer` fails past the device's resource size (128 MiB
is what every device guarantees), and past 4 GB `ByteWidth` (a `u32`) wrapped to a small buffer that the copy then
overran.

## Pages of instances

The frame's instances go to the GPU in pages: one buffer per page, each at most the device's largest buffer
(`maxBufferSize` as the device was given it; on Direct3D 11, `D3D11_BUFFER_BYTES_MAX` = 128 MiB). A batch's run of
instances is cut where a page ends (`page_run`): one draw per piece, each with its page bound and its first instance
counted from that page. The shaders never read `instance_index`, so the cut changes nothing they compute. A page grows by
doubling up to its limit and shrinks as the one buffer did (`shrink_due`); a page no frame used is released.

Refused: one buffer bound at an offset. The offset does not lift the limit on the buffer's size. Refused: raising
`requiredLimits` to the adapter's `maxBufferSize`. It moves the limit, it does not remove it, and a frame twice as large
aborts again.

## What cannot be split

A storage table (transforms, clips, points, gradients, an application shader's parameters) is bound whole, and its
instances index it: it cannot be cut. Past `maxStorageBufferBindingSize` the elements past the limit are not uploaded;
the shader reads zeros for them (WebGPU's robust access), and one line on standard error says so once per renderer. The
retained heaps refuse a picture that would pass their limit: `heap_alloc` returns false, as for a buffer the device
refuses. A frame whose constants (one 256-byte entry per batch) pass the largest buffer is not drawn.

The last defence: an error reported since the last submit skips the submit (`wgpu_submit`). The frame is lost and the
error printed; the process goes on. It was GL's alone; it is every backend's now: a renderer's bug on Vulkan is a lost
frame and a line in the log, not an abort.

A lost frame (`wgpu_frame_lost`) is not presented: the window keeps the picture it shows, not a surface texture nothing
was drawn to. The kept target of partial redraw was marked ready by the lost frame's own blit: it is marked behind, so
the next frame is drawn whole, not composed over a frame that never reached it (`src/render/lost_submit_test.odin`).
The skip is not only the frame's: the copy of a retained heap that grows is a submit too. A skipped copy leaves the old
heap in place and refuses the picture, as a buffer the device refuses: adopting the new heap would lose every picture
in it. The error counter does not say which command made the error, so one error costs one submit, whichever comes
next; an error on every frame loses every frame (the log says each). A new device starts with the count as it is: the
errors of the device before it (its calls once lost) never skip the first frame of the one recovered.

## The cull before the GPU

`gt:draw` makes no instance of a rectangle or an image wholly outside the current clip (plus one pixel for an antialiased
edge and a clip off the pixel grid), when nothing is recorded: a picture is replayed elsewhere. Text did this already. A
program that draws a row per line of a long text stays bounded by what the view shows, with no cull of its own. Only
the simple transform (scale and offset) is culled: a rotated rectangle's bounds cost more to compute than the instance.

The test: `src/render/instance_pages_test.odin` draws a frame of 512 one-pixel rectangles from pages of 100 on the
software device, and checks every pixel. `tests/layers` checks that a million rows under a clip of four make at most 8
instances.
