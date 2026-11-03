type: Changed

**Word cache**: a shard's lock is shared by the threads that find their word in its current generation (a page's threads shaping the same words: 190 ns per word with 8 threads instead of 440).
