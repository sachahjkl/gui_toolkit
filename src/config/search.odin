package tk_config

import "core:strings"

// The search of a settings UI made of pages: which preferences a query shows, and where each page's heading goes. The UI keeps
// its own layout and draws; this only says what shows. A frame of a search:
//
//   search_begin(&s, query)                  (the field's text; "": no search, everything shows)
//   for each page:
//       search_page(&s, page_title)          (a page whose title has every word of the query shows all its preferences)
//       for each preference row:
//           show, heading := search_shows(&s, &prefs, name)
//           if heading != "" { draw the page's heading }     (before its first preference that shows, once)
//           if show { draw the row }
//   if searching(&s) && s.found == 0 { say that nothing matches }
//
// A preference matches when every word of the query is in its name, its title or its description (matches).
Search :: struct {
	query:      string,   // lower case, trimmed (temp memory)
	page_whole: bool,     // the current page's title matches: all of it shows
	heading:    string,   // the current page's title, until its first preference shows
	found:      int,      // preferences shown since search_begin
}

search_begin :: proc(s: ^Search, query: string) {
	s^ = {query = strings.to_lower(strings.trim_space(query), context.temp_allocator)}
}

// Whether a query is typed (the UI shows the results of every page instead of one page).
searching :: proc(s: ^Search) -> bool { return s.query != "" }

search_page :: proc(s: ^Search, title: string) {
	s.heading = title
	s.page_whole = false
	if s.query == "" { return }
	t := strings.to_lower(title, context.temp_allocator)
	q := s.query
	for word in strings.fields_iterator(&q) { if !strings.contains(t, word) { return } }
	s.page_whole = true
}

// Whether the preference `name` shows. `heading`: the page's title, the first time one of its preferences shows in a search ("" else).
search_shows :: proc(s: ^Search, p: ^Prefs, name: string) -> (show: bool, heading: string) {
	if s.query == "" { return true, "" }
	if !s.page_whole {
		r := ref_of(p, name)
		if r == NO_REF || !matches(entry(p, r).def, s.query) { return false, "" }
	}
	s.found += 1
	heading, s.heading = s.heading, ""
	return true, heading
}

// Whether every word of `query` (separated by spaces, in any case) is in one of `fields` (in any case): a search over several
// fields of one thing, each word in any of them ("kernel ses_e3" finds a session by its title and its id). An empty query
// matches everything.
words_match :: proc(query: string, fields: ..string) -> bool {
	q := strings.to_lower(query, context.temp_allocator)
	low := make([]string, len(fields), context.temp_allocator)
	for f, i in fields { low[i] = strings.to_lower(f, context.temp_allocator) }
	for word in strings.fields_iterator(&q) {
		found := false
		for f in low { if strings.contains(f, word) { found = true; break } }
		if !found { return false }
	}
	return true
}
