type: Changed

**Native text backend (`gt_text`) uses ICU4X's LSTM line segmenter**: switches `icu_segmenter` from the 1.01 MiB
dictionary data to the 303 KiB LSTM model for Thai, Lao, Khmer, and Myanmar line breaking, trimming ~725 KiB of
`.rodata` from every binary that links `gt_text`.
