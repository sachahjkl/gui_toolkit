package tk

import "core:os"
import "core:testing"

// What GitHub's API says of a release: the id of the asset by its name, whatever the order, as an integer or a float.
@(test)
a_release_names_its_assets :: proc(t: ^testing.T) {
	release := `{"tag_name":"v1","assets":[{"id":11,"name":"a.zip"},{"id":705909133,"name":"odin-linux-amd64-dev.tar.gz"},{"id":12.0,"name":"b.zip"}]}`
	testing.expect_value(t, release_asset_id(release, "odin-linux-amd64-dev.tar.gz"), "705909133")
	testing.expect_value(t, release_asset_id(release, "b.zip"), "12")
	testing.expect_value(t, release_asset_id(release, "missing.zip"), "")
	testing.expect_value(t, release_asset_id("not json", "a.zip"), "")
}

// Only a file of a GitHub release goes through the API; anything else is not asked of it (and nothing is written).
@(test)
only_a_release_goes_through_the_api :: proc(t: ^testing.T) {
	path := join({temp_folder(), "tk_not_a_release.bin"})
	defer os.remove(path)
	testing.expect(t, !download_through_api("https://example.com/a/b/releases/download/v1/x.zip", path, true), "another host")
	testing.expect(t, !download_through_api("https://github.com/owner/repo/archive/refs/tags/v1.zip", path, true), "not a release's file")
	testing.expect(t, !os.exists(path), "nothing written")
}
