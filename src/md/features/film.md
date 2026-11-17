# Films of an interface

`gt:film` records a program made with the toolkit as a video file. The program draws its own frames, with no window of
the system. A script drives it as a person would: a pointer that glides, clicks, keys, typed words. A video presents a
tool, shows a change, or goes on a site.

## The pipeline

- The program opens a headless window (`host.Open_Options.headless`) with `headless_gpu`: it draws on the graphics card
  when there is one. On the software renderer, a 1080p film took more than 15 minutes; on the card, 32 seconds.
- Its time is the film's: `ui.set_clock` gives the State a clock that moves by 1/fps a frame. Every animation, delay and
  ease follows it. A film is made faster than it plays, and two runs give the same pictures.
- Each frame is read back as the renderer stores it (`render.read_frame_raw`, B8G8R8A8) and written raw to ffmpeg's
  standard input (`-f rawvideo -pix_fmt bgr0`). ffmpeg encodes as the frames come: no picture file between.
- A thread of its own writes a frame while the next one is drawn. In sequence, the writes doubled the time of a frame.
- NVENC when it works (a probe of one short encode): `h264_nvenc`, preset p4, the YUV made on the card from the RGB.
  Else `libx264`, on the processor. p7 gave the same pictures (SSIM 0.998) and stalled the pipe on the busiest frames.

## The stage

A film is a fixed size; the program's window may be smaller and change size (a film of a layout that narrows). The
window then stands on a stage: a gradient ground, the window centred on it with rounded corners and a soft shadow. The
ground and the shadow are made once per window size and copied under each frame. The pointer's places are the window's
client pixels; the stage moves them by the window's offset.

## The pointer

The film draws a pointer over each frame: an arrow with an outline and a shadow, slightly smaller while a button is
down, and a ring that spreads from each click. A film without it shows things change with no cause. The arrow is made
once, at the film's scale, with its edges smoothed by supersampling.

A script moves the pointer over time: `move_to` glides along an ease, one event per frame, so hovers light up on the way.
A test's session jumps instead (`tk_session.move`): its aim is the end state, not the way.

## Refused

- fframes or another compositor (titles, transitions in SVG over the clips): a second renderer, with Skia and a static
  ffmpeg to fetch. The toolkit draws its own titles, and its exploded view turns a page in 3D.
- PNG files then an encode: an 8 MB frame compressed and read again for nothing.
- A film made by the session of a test: it needs a `testing.T`, and its input jumps.
