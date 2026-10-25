// Writes everything the font package says about the corpus of tools/text_corpus to a file (or stdout), for a diff
// between two builds (the same backend before and after a change: nothing may move).
//   odin run tools/text_dump -vet -out:build/text_dump.exe -- out.txt
package text_dump

import "core:fmt"
import "core:os"
import "../../font"
import corpus "../text_corpus"

main :: proc() {
	s := new(font.State)
	font.init(s)
	defer { font.destroy(s); free(s) }
	if !s.ok { fmt.eprintln("text_dump: the font backend did not start"); os.exit(1) }
	out := corpus.dump(s)
	if len(os.args) > 1 {
		if err := os.write_entire_file(os.args[1], transmute([]byte)out); err != nil { fmt.eprintln("text_dump: cannot write", os.args[1]); os.exit(1) }
	} else {
		fmt.print(out)
	}
}
