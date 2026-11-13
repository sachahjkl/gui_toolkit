package tk_toolbox

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../fsx"
import licence "../licence"

@(private = "file")
TOOL_PRODUCT :: licence.Product{
	name           = "sample",
	title          = "Sample",
	version_tag    = "SAMPLE1",
	sign_context   = "sample-licence-v1\n",
	file_extension = ".samplelicence",
	dev_public_key = "zHs7wxUEefqH37-vN5cKoTnZOCCFBnmcoQGrw6i3UAk",
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}

@(private = "file")
tool_in :: proc(dir: string) -> Licence_Tool {
	return {product = TOOL_PRODUCT, key_dir = dir, dev_seed = "Z3QtbGljZW5jZS1zYW1wbGUtZGV2LXNlZWQtMDAwMSE", hint = "Open this file with Sample.",
		paddle = {name = "Sample User Licence", description = "A licence of Sample.", amounts = "supporter=2900", currency = "EUR"}}
}

@(private = "file")
scratch_dir :: proc(name: string) -> string {
	dir := fmt.tprintf("%s/gt-toolbox-licence-%s-%d", fsx.temp_dir(context.temp_allocator), name, os.get_pid())
	_ = fsx.remove_tree(dir)
	return dir
}

@(test)
licence_commands_are_named :: proc(t: ^testing.T) {
	c := licence_commands(tool_in(""))
	defer free(c[0].user)
	testing.expect_value(t, c[0].name, "licence")
	testing.expect_value(t, c[1].name, "paddle")
	testing.expect_value(t, args_check(c[1], {"-apply", "-amounts:supporter=1"}), "")
	testing.expect(t, args_check(c[1], {"-nope"}) != "")
}

@(test)
licence_keys_and_issue :: proc(t: ^testing.T) {
	dir := scratch_dir("keys")
	defer fsx.remove_tree(dir)
	tool := tool_in(fmt.tprintf("%s/not/made/yet", dir))
	testing.expect_value(t, licence_keygen(tool, nil), "")
	key_file := fmt.tprintf("%s/not/made/yet/private.key", dir)
	testing.expect(t, fsx.path_kind(key_file) == .File)
	testing.expect(t, licence_keygen(tool, nil) != "", "a second key is refused")
	testing.expect_value(t, licence_keygen(tool, {"-force"}), "")
	testing.expect_value(t, licence_pubkey(tool, nil), "")

	// with the pair just made: the file says the licence, the program's check takes it with the printed key
	out := fmt.tprintf("%s/issued.samplelicence", dir)
	testing.expect_value(t, licence_issue(tool, {"-name:Jeanne Dupont", "-email:jeanne@example.org", "-edition:patron", "-order:SAMPLE-7", "-date:2026-10-22", fmt.tprintf("-out:%s", out)}), "")
	file, _ := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(file), "# Sample licence (Patron) for Jeanne Dupont\n# Order SAMPLE-7, 2026-10-22.\n# Open this file with Sample.\n"), string(file))
	data, _ := os.read_entire_file(key_file, context.temp_allocator)
	seed, ok := licence.key_decode(licence.normalize(string(data), context.temp_allocator))
	testing.expect(t, ok)
	pub, _ := licence.public_key_of(seed[:], context.temp_allocator)
	lic, err := licence.verify(TOOL_PRODUCT, string(file), pub, context.temp_allocator)
	testing.expect_value(t, err, licence.Error.None)
	testing.expect_value(t, lic.edition, "patron")
	testing.expect_value(t, licence_verify(tool, {out, fmt.tprintf("-public:%s", pub)}), "")
	testing.expect(t, licence_verify(tool, {out}) != "", "the product's key (none) refuses it")
	testing.expect(t, licence_verify(tool, {out, "-dev"}) != "", "the development pair refuses it")

	// what the program would refuse is not issued
	testing.expect(t, licence_issue(tool, {"-name:N", "-order:1", "-edition:founder"}) != "")
	testing.expect(t, licence_issue(tool, {"-name:N", "-order:1", "-date:22/10/2026"}) != "")
	testing.expect(t, licence_issue(tool, {"-email:e"}) != "")
	// -dev: the development pair, the issued file in the key folder by default
	testing.expect_value(t, licence_issue(tool, {"-dev", "-name:Dev", "-order:A/B"}), "")
	testing.expect(t, fsx.path_kind(fmt.tprintf("%s/not/made/yet/issued/A_B.samplelicence", dir)) == .File)
	testing.expect_value(t, licence_verify(tool, {fmt.tprintf("%s/not/made/yet/issued/A_B.samplelicence", dir), "-dev"}), "")
}

@(test)
licence_key_stays_out_of_work_trees :: proc(t: ^testing.T) {
	testing.expect(t, in_git_tree("src/toolbox/no/such/folder/private.key"), "a folder still to make in a work tree")
	testing.expect(t, !in_git_tree(fmt.tprintf("%s/no/such/folder/private.key", fsx.temp_dir(context.temp_allocator))), "the temporary folder")
	tool := tool_in("src/toolbox/no-such-folder")
	testing.expect(t, strings.has_prefix(licence_keygen(tool, nil), "refused"))
	testing.expect(t, fsx.path_kind("src/toolbox/no-such-folder") == .Absent)
	testing.expect(t, strings.has_suffix(licence_key_dir(tool_in("")), "sample-licence") || licence_key_dir(tool_in("")) == "")
}

// (run from the repository's root, as the suite does)
@(test)
licence_secrets_cannot_be_committed :: proc(t: ^testing.T) {
	root, _ := os.read_entire_file(".gitignore", context.temp_allocator)
	testing.expect(t, strings.contains(string(root), "private.key"))
	worker, _ := os.read_entire_file("licence-worker/.gitignore", context.temp_allocator)
	testing.expect(t, strings.contains(string(worker), "secrets*.env"))
}

@(test)
dotenv_keeps_the_workers_secrets :: proc(t: ^testing.T) {
	text := "LICENSE_PRIVATE_KEY=abc\nPADDLE_LIVE_SETUP_KEY=wide\n# a comment\nPADDLE_API_KEY=k=v\nnot a line\n"
	keys := WORKER_SECRETS
	kept, names := dotenv_keep(text, keys[:])
	testing.expect_value(t, kept, "LICENSE_PRIVATE_KEY=abc\nPADDLE_API_KEY=k=v\n")
	testing.expect_value(t, len(names), 2)
	testing.expect(t, !strings.contains(kept, "SETUP"))
	// out of a work tree only when git ignores it
	testing.expect(t, strings.has_prefix(sops_dotenv("none.yaml", "src/toolbox/secrets.env", keys[:]), "refused"))
}

@(test)
paddle_catalogue_bodies :: proc(t: ^testing.T) {
	tool := tool_in("")
	amounts, ok := paddle_amounts(TOOL_PRODUCT, "supporter=2900, patron=9900")
	testing.expect(t, ok)
	testing.expect_value(t, len(amounts), 2)
	for bad in ([]string{"", "supporter", "supporter=", "supporter=29.00", "founder=100"}) {
		_, good := paddle_amounts(TOOL_PRODUCT, bad)
		testing.expectf(t, !good, "%q", bad)
	}
	product := paddle_product_body(tool.paddle)
	testing.expect_value(t, product, `{"name":"Sample User Licence","tax_category":"standard","description":"A licence of Sample."}`)
	price := paddle_price_body(TOOL_PRODUCT, tool.paddle, "pro_1", amounts[1])
	v, err := json.parse_string(price, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	o := v.(json.Object)
	testing.expect_value(t, string(o["product_id"].(json.String)), "pro_1")
	testing.expect_value(t, string(o["name"].(json.String)), "Patron")
	testing.expect_value(t, string(o["tax_mode"].(json.String)), "internal")
	testing.expect_value(t, string(o["custom_data"].(json.Object)["edition"].(json.String)), "patron")
	testing.expect_value(t, string(o["unit_price"].(json.Object)["amount"].(json.String)), "9900")
	testing.expect(t, !strings.contains(paddle_price_body(TOOL_PRODUCT, tool.paddle, "", amounts[0]), "product_id"))
	testing.expect_value(t, paddle_prices_setting({"pri_a", "pri_b"}, amounts), `{"pri_a":"supporter","pri_b":"patron"}`)
}
