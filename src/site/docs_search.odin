package tk_site

// The documentation's search: an index the page loads once (a JSON array: each page's address, title, section and the start of
// its plain text), and a script with no dependency that scores a query against it. No server, no request elsewhere.

import "core:strings"

Search_Doc :: struct {
	url:     string,   // root-absolute: "/docs/cdp/"
	title:   string,
	section: string,
	text:    string,
}

// The bytes of a page's text that go into the index: a long page needs only a representative start to be found, and the whole
// index stays a small download.
SEARCH_TEXT_MAX :: 1400

search_index_json :: proc(docs: []Search_Doc) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for d, i in docs {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, "{\"u\":")
		write_json_text(&b, d.url)
		strings.write_string(&b, ",\"t\":")
		write_json_text(&b, d.title)
		strings.write_string(&b, ",\"s\":")
		write_json_text(&b, d.section)
		strings.write_string(&b, ",\"b\":")
		write_json_text(&b, truncate_text(d.text, SEARCH_TEXT_MAX))
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]\n")
	return strings.to_string(b)
}

// A JSON string of `s`: a tab as a space, the other control characters but '\n' dropped.
@(private)
write_json_text :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\t': strings.write_byte(b, ' ')
		case:
			if c >= 0x20 { strings.write_byte(b, c) }
		}
	}
	strings.write_byte(b, '"')
}

// At most n bytes of `s`, not in the middle of a UTF-8 sequence, at the last space when one is near the end.
@(private)
truncate_text :: proc(s: string, n: int) -> string {
	if len(s) <= n { return s }
	cut := n
	for cut > 0 && (s[cut] & 0xC0) == 0x80 { cut -= 1 }
	if sp := strings.last_index_byte(s[:cut], ' '); sp > n - 40 { cut = sp }
	return s[:cut]
}

// The search script. `index` is the index's address relative to the script (a second presentation of the docs may share
// another's index); the hits are pages of the site the script is in. "/" focuses the box (unless the reader types in a field),
// Enter opens the first hit, Escape clears.
search_js :: proc(index: string) -> string {
	return strings.concatenate({SEARCH_JS_HEAD, index, SEARCH_JS_TAIL})
}

@(private = "file")
SEARCH_JS_HEAD :: `(function(){
var box=document.getElementById('doc-search-input');
var out=document.getElementById('doc-search-results');
if(!box||!out)return;
var here=(document.currentScript&&document.currentScript.src)||'';var base=here.slice(0,here.lastIndexOf('/')+1);var site=base.replace(/docs\/$/,'');
var idx=null,loading=false;
function load(cb){if(idx){cb();return;}if(loading)return;loading=true;
fetch(base+'`

@(private = "file")
SEARCH_JS_TAIL :: `').then(function(r){return r.json();}).then(function(d){idx=d;cb();});}
function norm(s){return (s||'').toLowerCase();}
function score(d,terms){var t=norm(d.t),s=norm(d.s),b=norm(d.b),sc=0;
for(var i=0;i<terms.length;i++){var w=terms[i];if(!w)continue;var hit=0;
if(t.indexOf(w)>=0){sc+=10;hit=1;}if(s.indexOf(w)>=0){sc+=4;hit=1;}
var p=b.indexOf(w);if(p>=0){sc+=2;hit=1;}if(!hit)return 0;}
return sc;}
function snippet(b,terms){var t=norm(b),p=-1;
for(var i=0;i<terms.length;i++){var q=t.indexOf(terms[i]);if(q>=0&&(p<0||q<p))p=q;}
if(p<0)p=0;var start=Math.max(0,p-40);var s=b.slice(start,start+150);
return (start>0?'…':'')+s+(start+150<b.length?'…':'');}
function esc(s){return s.replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
function run(){var q=box.value.trim();if(!q){out.hidden=true;out.innerHTML='';return;}
load(function(){var terms=norm(q).split(/\s+/);var hits=[];
for(var i=0;i<idx.length;i++){var sc=score(idx[i],terms);if(sc>0)hits.push([sc,idx[i]]);}
hits.sort(function(a,b){return b[0]-a[0];});hits=hits.slice(0,8);
if(!hits.length){out.innerHTML='<p class="doc-search-none">No matches.</p>';out.hidden=false;return;}
var h='<ul>';for(var i=0;i<hits.length;i++){var d=hits[i][1];
h+='<li><a href="'+site+d.u.replace(/^\//,'')+'"><span class="r-sec">'+esc(d.s||'')+'</span><strong>'+esc(d.t)+'</strong>'+
'<span class="r-snip">'+esc(snippet(d.b,terms))+'</span></a></li>';}
h+='</ul>';out.innerHTML=h;out.hidden=false;});}
box.addEventListener('input',run);
box.addEventListener('keydown',function(e){if(e.key==='Escape'){box.value='';out.hidden=true;box.blur();}
if(e.key==='Enter'){var a=out.querySelector('a');if(a){e.preventDefault();location.href=a.href;}}});
document.addEventListener('keydown',function(e){if(e.key==='/'&&document.activeElement!==box){
var tag=(document.activeElement||{}).tagName;if(tag==='INPUT'||tag==='TEXTAREA')return;
e.preventDefault();box.focus();}});
document.addEventListener('click',function(e){if(!out.contains(e.target)&&e.target!==box)out.hidden=true;});
})();
`
