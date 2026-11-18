package tk_plugins

// What a plugin asks (its manifest's "permissions") and what the person granted (plugins.toml), as the program keeps
// them (plugins.md, decision 4). A permission is a word: "files", "folder:documents", "folder:downloads",
// "clipboard.read", "clipboard.write", "net:*" (any public address) or "net:<origin>" ("https://api.example.com",
// "http://localhost:8080": the machine's own and the local network's addresses only when named so).

import "core:fmt"
import "core:strings"
import "../ascii"
import http "../http"
import plugin_api "../plugin_api"

// One permission, read.
Permission :: struct {
	capability: plugin_api.Capability,
	origin:     string,   // Net: "scheme://host[:port]" in lower case, the port only when it is not the scheme's; "*": any public
}

// A permission's word as the manifest writes it, read and put in its one form (an origin in lower case, without its
// default port). ok false: no such permission.
permission_parse :: proc(word: string, allocator := context.temp_allocator) -> (p: Permission, normal: string, ok: bool) {
	switch word {
	case "files":            return {capability = .Files}, strings.clone(word, allocator), true
	case "folder:documents": return {capability = .Documents}, strings.clone(word, allocator), true
	case "folder:downloads": return {capability = .Downloads}, strings.clone(word, allocator), true
	case "clipboard.read":   return {capability = .Clipboard_Read}, strings.clone(word, allocator), true
	case "clipboard.write":  return {capability = .Clipboard_Write}, strings.clone(word, allocator), true
	case "net:*":            return {capability = .Net, origin = "*"}, strings.clone(word, allocator), true
	}
	if !strings.has_prefix(word, "net:") { return }
	rest := word[len("net:"):]
	// (an origin, not an address: a path or a query says more than an origin is)
	if u, parsed := http.url_parse(rest); !parsed || u.path != "/" { return }
	origin, good := origin_of(rest, allocator)
	if !good { return }
	return {capability = .Net, origin = origin}, strings.concatenate({"net:", origin}, allocator), true
}

// The origin of an address: "https://host[:port]", the host in lower case, the port when it is not the scheme's.
origin_of :: proc(url: string, allocator := context.temp_allocator) -> (string, bool) {
	u, ok := http.url_parse(url)
	if !ok { return "", false }
	scheme := u.secure ? "https" : "http"
	default_port := u.secure ? 443 : 80
	host := ascii.lower(u.host)   // (origins compare as text: a host name folds by ASCII)
	if u.port == default_port { return fmt.aprintf("%s://%s", scheme, host, allocator = allocator), true }
	return fmt.aprintf("%s://%s:%d", scheme, host, u.port, allocator = allocator), true
}

// Whether `host` is the machine's own or the local network's: a name such as localhost or *.local, an address of the
// loopback, of a private range or a link's. Such a host is reached only by an origin named for it, never by "net:*".
// (By its text only: a public name whose system's answer is a private address is not seen here.)
host_is_private :: proc(host: string) -> bool {
	h := ascii.lower(host)   // (a host name folds by ASCII: an IDN comes as its punycode)
	h = strings.trim(h, "[]")
	if h == "localhost" || strings.has_suffix(h, ".localhost") || strings.has_suffix(h, ".local") || strings.has_suffix(h, ".internal") { return true }
	if strings.contains(h, ":") {   // (IPv6)
		return h == "::1" || h == "::" || strings.has_prefix(h, "fe80:") || strings.has_prefix(h, "fc") || strings.has_prefix(h, "fd") || strings.has_prefix(h, "::ffff:")
	}
	parts := strings.split(h, ".", context.temp_allocator)
	if len(parts) != 4 { return false }
	n: [4]int
	for part, i in parts {
		if part == "" || len(part) > 3 { return false }
		for c in transmute([]u8)part { if c < '0' || c > '9' { return false } }
		for c in transmute([]u8)part { n[i] = n[i] * 10 + int(c - '0') }
	}
	switch {
	case n[0] == 127, n[0] == 10, n[0] == 0:       return true
	case n[0] == 169 && n[1] == 254:                return true
	case n[0] == 172 && n[1] >= 16 && n[1] <= 31:   return true
	case n[0] == 192 && n[1] == 168:                return true
	case n[0] == 100 && n[1] >= 64 && n[1] <= 127:  return true   // (the carriers' shared space)
	}
	return false
}

// Whether the permissions `granted` let a request go to `url`: an origin named, or "net:*" and a public host.
net_allowed :: proc(granted: []string, url: string) -> bool {
	origin, ok := origin_of(url)
	if !ok { return false }
	u, _ := http.url_parse(url)
	for g in granted {
		if !strings.has_prefix(g, "net:") { continue }
		o := g[len("net:"):]
		if o == origin { return true }
		if o == "*" && !host_is_private(u.host) { return true }
	}
	return false
}

// The capabilities of a set of granted words: what the bridge of the plugin's process may let through at once.
capabilities_of :: proc(granted: []string) -> plugin_api.Capabilities {
	caps: plugin_api.Capabilities
	for g in granted {
		if p, _, ok := permission_parse(g); ok { caps += {p.capability} }
	}
	return caps
}

// Whether every word of `asked` is in `granted`: a new version that asks more asks again.
permissions_covered :: proc(asked, granted: []string) -> bool {
	for a in asked {
		found := false
		for g in granted { found ||= g == a }
		if !found { return false }
	}
	return true
}

// What a permission lets the plugin do, in words, for the grant dialog.
permission_words :: proc(word: string) -> string {
	switch word {
	case "files":            return "Open the files and folders you pick for it"
	case "folder:documents": return "Read and write in your Documents folder"
	case "folder:downloads": return "Read and write in your Downloads folder"
	case "clipboard.read":   return "Read the clipboard, when you use the plugin"
	case "clipboard.write":  return "Put text on the clipboard"
	case "net:*":            return "Connect to any address on the internet"
	}
	if strings.has_prefix(word, "net:") { return fmt.tprintf("Connect to %s", word[len("net:"):]) }
	return word
}
