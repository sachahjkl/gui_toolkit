type: Fixed

**`flate.inflate_push`**: a big block that arrives in many chunks is no longer decoded again from its start with each one (quadratic time): its output comes as its input arrives. Inflating and deflating no longer fill the temporary allocator.
