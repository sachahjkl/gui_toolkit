package tk_desktop

// An identity's names and marks from the vendor, the title and the slug (src/md/features/vendor-facts.md): the rule every
// program followed by hand, said once.

import "core:strings"
import "../ascii"
import "../platform"

// The Identity of a program of `vendor` ("Froment Software") named `title` ("Opencode Native"), whose files are `slug`
// ("opencode-native"). The key and the vendor's key are PascalCase by the AppUserModelID's rule ("OpencodeNative",
// "FromentSoftware"); the marks are X-<key>-Integration and <key>Integration; the manifest is <slug>_install.txt; the
// environment's prefix <SLUG>_DESKTOP_. The program sets its own lines after (description, categories, actions...), and
// a mark of another rule that installed copies already carry. The strings are allocated in `allocator`, for as long as
// the identity is used: options_clone shares them with the jobs.
identity_of :: proc(vendor, title, slug: string, allocator := context.allocator) -> Identity {
	key := platform.app_user_model_id("", title, allocator)
	prefix := strings.builder_make(allocator)
	for i in 0 ..< len(slug) {
		c := slug[i]
		strings.write_byte(&prefix, c == '-' ? '_' : ascii.upper_byte(c))
	}
	strings.write_string(&prefix, "_DESKTOP_")
	return Identity{
		name          = title,
		key           = key,
		slug          = slug,
		vendor        = vendor,
		vendor_key    = platform.app_user_model_id("", vendor, allocator),
		entry_marker  = strings.concatenate({"X-", key, "-Integration"}, allocator),
		registry_mark = strings.concatenate({key, "Integration"}, allocator),
		manifest_name = strings.concatenate({slug, "_install.txt"}, allocator),
		env_prefix    = strings.to_string(prefix),
	}
}
