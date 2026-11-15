type: Changed

**One native library.** The text backend, Mermaid and AccessKit are one static library, `build/native/gt_native.lib` (`libgt_native.a`), built by `tk build_native -features:text,mermaid,a11y` with one copy of Rust's standard library; `build_text`, `build_mermaid` and `build_a11y` are gone, and `toolbox.build_native` builds the parts a program's features ask for. A program with a Rust library of its own still builds the part's crate (`native/text`...) into it.
