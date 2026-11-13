// The tool of the sample product of the worker's tests (cross.test.ts builds it): the toolkit's licence commands, as a
// program's tool has them. Also an example of the few lines a program writes.
package sample_tool

import licence "../../../src/licence"
import toolbox "../../../src/toolbox"

SAMPLE :: licence.Product{
	name           = "sample",
	title          = "Sample",
	version_tag    = "SAMPLE1",
	sign_context   = "sample-licence-v1\n",
	file_extension = ".samplelicence",
	dev_public_key = "zHs7wxUEefqH37-vN5cKoTnZOCCFBnmcoQGrw6i3UAk",
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}

main :: proc() {
	commands := toolbox.licence_commands({
		product  = SAMPLE,
		dev_seed = "Z3QtbGljZW5jZS1zYW1wbGUtZGV2LXNlZWQtMDAwMSE",   // the development pair: public on purpose
		hint     = "Open this file with Sample.",
		paddle   = {name = "Sample User Licence", description = "A licence of Sample.", amounts = "supporter=2900,patron=9900", currency = "EUR"},
	})
	toolbox.tool_main("sample", commands[:])
}
