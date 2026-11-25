# MP4 and WebM muxers: who owns a sample

`gt:mux` is a port of Mediabunny, which runs on a garbage collector. A pointer kept to a sample already written is
harmless there. Here it is a write into freed memory. So the ownership below is part of the design, not a detail of the
port: a change taken from Mediabunny is read against it.

## The fragmented MP4

- A sample is owned by its track's `sample_queue`, then by `current_chunk`. `finalize_fragment` writes the chunk and
  frees it with its samples. A long recording holds one fragment in memory, not the file.
- `timestamp_queue` and `last_sample` only point at samples. Neither keeps one alive.
- `timestamp_queue` is always empty of a chunk's samples when the chunk goes. A fragment ends only when every open track
  starts the next one with a key frame, and a key frame is registered after the group before it was timed.
- `last_sample` is not: the key frame that times a group also ends its fragment. The next group still wants to say how
  long that sample lasted. `finalize_fragment` sets it to nil when it frees that sample, and `process_timestamps` says
  nothing to a nil one. The refinement is lost for the last sample of a fragment, as it is in Mediabunny: its trun is
  already in the file.
- With two tracks, a sample already timed can wait in its queue for the other track. So `last_sample` is cleared when its
  own sample goes, not at each fragment.

Not fragmented, the track's `samples` own every sample until the end.

## The test

`tests/mux/freed_test.odin` gives the muxer an allocator that fills a freed block, never gives it out again and checks
the fill at the end. An address sanitizer finds the same fault. The allocator finds it on every system and in the plain
test run.

A freed sample is 72 bytes, so the write lands in whatever the heap puts there next. A recorder crashed so in the free
list of the C heap, under the muxer's next `free` and once under a `malloc` of NVIDIA's encoder: the crash names a
victim.

## Refused

- **Samples kept until the next group is timed.** It delays each free by a fragment for a value that no box can hold any
  more.
- **A fragment held back until its last sample's duration is known.** A crash then loses one fragment more of the
  recording. The packet's own duration is already that sample's.
