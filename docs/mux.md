# mux: MP4 and WebM files

`import mux "gt:mux"` (the package is named `tk_mux`). Encoded video and audio packets in, a playable file out: MP4
(ISOBMFF) or WebM (Matroska), in memory, in a file, or through a writer procedure. What a screen recorder needs to write
its H.264 (`gt:h264`) with no ffmpeg. Pure Odin, any target. Every procedure blocks on its output: call them on a
worker.

```odin
m, err := mux.mp4_open_file("out.mp4", {fast_start = .Fragmented})
track, _ := mux.add_video_track(m, {codec = .AVC, width = 1920, height = 1080, frame_rate = 30})
for p in packets { mux.add_packet(m, track, p.data, p.timestamp, 1.0 / 30, p.keyframe) }   // seconds
_, err = mux.finalize(m)   // (a memory muxer gives its bytes here)
```

| Procedure | |
|---|---|
| `mp4_open_memory(o)`, `mp4_open_file(path, o)`, `mp4_open_stream(write, user, o)` (`mp4_open`) | an MP4 muxer. |
| `webm_open_memory`, `webm_open_file`, `webm_open_stream` (`webm_open`) | a WebM muxer. |
| `add_video_track(m, Video_Track)`, `add_audio_track(m, Audio_Track)` | before the first packet. |
| `add_packet(m, track, data, timestamp, duration, key)` | times in seconds; a track's first packet is a key frame. |
| `close_track(m, track)` | no more packets on it. |
| `finalize(m) -> (data, err)` | writes what is left (the moov, the Cues, the sizes) and frees the muxer; `data` is a memory muxer's file. |
| `destroy(m)` | frees a muxer not finalized. |

`Write_Proc :: proc(user, data, position) -> bool`: a stream muxer's bytes, each at its position. Positions follow each
other, except for a patch of bytes already given (an MP4's mdat size without fast start; a WebM's Segment size,
duration and SeekHead): a stream that cannot seek uses `fast_start = .Fragmented` (MP4) or `append_only` (WebM).

## Codecs

| | MP4 | WebM |
|---|---|---|
| H.264 (`.AVC`) | Annex B (the SPS and PPS of the first packet make the avcC) or AVCC with its avcC | no |
| H.265 (`.HEVC`) | length-prefixed, with its hvcC | no |
| VP8, VP9, AV1 | yes | yes |
| AAC | raw with its AudioSpecificConfig, or ADTS | no |
| Opus | yes | yes |

## MP4

`Fast_Start`: `In_Memory` (the default in memory: the moov first, every packet kept until `finalize`), `Fragmented`
(a moof and its mdat a fragment, a fragment a key frame or so: a crash leaves the fragments written playable; an `mfra`
at the end), `Off` (the default for a file or a stream: packets go out in chunks of half a second, the moov at the end,
the mdat's size patched).

## WebM

SimpleBlocks in Clusters of at most a few seconds, Cues, a SeekHead, the duration written at the end. `append_only`:
unknown sizes, no SeekHead, no duration: a live stream.

## Licence

The muxers are a port of [Mediabunny](https://github.com/Vanilagy/mediabunny)'s (commit 173f6b7). The files ported
(`codec_data.odin`, `mp4.odin`, `mp4_boxes.odin`, `webm.odin`) keep Mediabunny's MPL-2.0 notice and say which file they
come from: a change to them stays under the MPL-2.0. `mux.odin` (the API and the output) is the toolkit's.

Left out: QuickTime (`.mov`), CMAF, fast start "reserve", subtitles, PCM, metadata tags, rotation.

Tests: `odin test tests/mux -vet` (synthetic H.264 access units muxed and the files walked back: an MP4 in memory, one
without fast start through a stream, a fragmented one, the composition offsets of B-frames, AAC and Opus tracks; WebM in
memory and append only; the errors).
