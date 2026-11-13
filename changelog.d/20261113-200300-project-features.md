type: Changed

**A program declares what it takes of the toolkit once**: `toolbox.Project.features` (`Native_Text`, `Accessibility`, `Mermaid`, `Devtools`, `Lucide_Subset`, `No_Fallback_Fonts`) gives `odin_command` its defines, `build_native` its steps (the native libraries, the Lucide subset) and the notices their crates. `build_native` replaces `build_native_text`, and `features` replaces `Project.native_crates`.
