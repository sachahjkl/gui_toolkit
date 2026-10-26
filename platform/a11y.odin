package platform

// Accessibility: what screen readers and other assistive technologies read of a window. The application (the toolkit's
// ui package, or an application's own content such as a web page) describes its nodes with the types below, in a flat
// update (A11y_Update) that carries only the nodes that changed; the platform's adapter turns it into what the system
// reads (UI Automation on Windows, through AccessKit: a11y_accesskit.odin), and hands back what the technologies ask
// for (click, focus, set a value, scroll...) as A11y_Request.
//
// Nothing is built while no assistive technology listens: a11y_state says Off, and the ui package skips its tree. The
// first time one asks for the window's tree, a11y_state says Full (send the whole tree), then Incremental (send what
// changed). The adapter is compiled in with -define:A11Y_ACCESSKIT=true (a11y_stub.odin otherwise: always Off).
// See docs/accessibility.md.

// Roles, in AccessKit's order (accesskit::Role): the adapter converts by index.
A11y_Role :: enum u8 {
	Unknown, Text_Run, Cell, Label, Image, Link, Row, List_Item, List_Marker, Tree_Item, List_Box_Option, Menu_Item,
	Menu_List_Option, Paragraph, Generic_Container, Check_Box, Radio_Button, Text_Input, Button, Default_Button, Pane,
	Row_Header, Column_Header, Row_Group, List, Table, Layout_Table_Cell, Layout_Table_Row, Layout_Table, Switch, Menu,
	Multiline_Text_Input, Search_Input, Date_Input, Date_Time_Input, Week_Input, Month_Input, Time_Input, Email_Input,
	Number_Input, Password_Input, Phone_Number_Input, Url_Input, Abbr, Alert, Alert_Dialog, Application, Article, Audio,
	Banner, Blockquote, Canvas, Caption, Caret, Code, Color_Well, Combo_Box, Editable_Combo_Box, Complementary, Comment,
	Content_Deletion, Content_Insertion, Content_Info, Definition, Description_List, Details, Dialog, Disclosure_Triangle,
	Document, Embedded_Object, Emphasis, Feed, Figure_Caption, Figure, Footer, Form, Grid, Grid_Cell, Group, Header,
	Heading, Iframe, Iframe_Presentational, Ime_Candidate, Keyboard, Legend, Line_Break, List_Box, Log, Main, Mark,
	Marquee, Math, Menu_Bar, Menu_Item_Check_Box, Menu_Item_Radio, Menu_List_Popup, Meter, Navigation, Note,
	Plugin_Object, Progress_Indicator, Radio_Group, Region, Root_Web_Area, Ruby, Ruby_Annotation, Scroll_Bar,
	Scroll_View, Search, Section, Section_Footer, Section_Header, Slider, Spin_Button, Splitter, Status, Strong,
	Suggestion, Svg_Root, Tab, Tab_List, Tab_Panel, Term, Time, Timer, Title_Bar, Toolbar, Tooltip, Tree, Tree_Grid,
	Video, Web_View, Window, Pdf_Actionable_Highlight, Pdf_Root, Graphics_Document, Graphics_Object, Graphics_Symbol,
	Doc_Abstract, Doc_Acknowledgements, Doc_Afterword, Doc_Appendix, Doc_Back_Link, Doc_Biblio_Entry, Doc_Bibliography,
	Doc_Biblio_Ref, Doc_Chapter, Doc_Colophon, Doc_Conclusion, Doc_Cover, Doc_Credit, Doc_Credits, Doc_Dedication,
	Doc_Endnote, Doc_Endnotes, Doc_Epigraph, Doc_Epilogue, Doc_Errata, Doc_Example, Doc_Footnote, Doc_Foreword,
	Doc_Glossary, Doc_Gloss_Ref, Doc_Index, Doc_Introduction, Doc_Note_Ref, Doc_Notice, Doc_Page_Break, Doc_Page_Footer,
	Doc_Page_Header, Doc_Page_List, Doc_Part, Doc_Preface, Doc_Prologue, Doc_Pullquote, Doc_Qna, Doc_Subtitle, Doc_Tip,
	Doc_Toc, List_Grid, Terminal,
}

// Boolean states of a node (0..17: accesskit::Flag's order), and the toolkit's own bits for optional booleans.
A11y_Flag :: enum u8 {
	Hidden, Multiselectable, Required, Visited, Busy, Live_Atomic, Modal, Touch_Transparent, Read_Only, Disabled,
	Italic, Clips_Children, Line_Breaking_Object, Page_Breaking_Object, Spelling_Error, Grammar_Error, Search_Match,
	Suggestion,
	Has_Expanded = 20, Expanded, Has_Selected, Selected, Has_Bounds,
}
A11y_Flags :: bit_set[A11y_Flag; u32]

// What an assistive technology may ask of a node (accesskit::Action's order).
A11y_Action :: enum u8 {
	Click, Focus, Blur, Collapse, Expand, Custom_Action, Decrement, Increment, Hide_Tooltip, Show_Tooltip,
	Replace_Selected_Text, Scroll_Down, Scroll_Left, Scroll_Right, Scroll_Up, Scroll_Into_View, Scroll_To_Point,
	Set_Scroll_Offset, Set_Text_Selection, Set_Sequential_Focus_Navigation_Starting_Point, Set_Value,
	Show_Context_Menu,
}
A11y_Actions :: bit_set[A11y_Action; u32]

// Properties beyond role, flags, actions, bounds and children. Strings: `a` = offset in bytes, `len`; numbers: `f`;
// integers and enumerations: `a`; node lists: `a` = offset in ids, `len`; one node: `a` = its id.
A11y_Prop_Kind :: enum u32 {
	Label = 1, Description, Value, Placeholder, Role_Description, State_Description, Keyboard_Shortcut, Access_Key,
	Html_Tag, Html_Id, Class_Name, Url, Language, Tooltip, Author_Id, Font_Family, Row_Index_Text, Column_Index_Text,

	Numeric_Value = 30, Min_Numeric_Value, Max_Numeric_Value, Numeric_Value_Step, Numeric_Value_Jump,
	Scroll_X, Scroll_X_Min, Scroll_X_Max, Scroll_Y, Scroll_Y_Min, Scroll_Y_Max,
	Font_Size = 45, Font_Weight,

	Row_Count = 50, Column_Count, Row_Index, Column_Index, Row_Span, Column_Span, Level, Size_Of_Set, Position_In_Set,

	Toggled = 60,         // A11y_Toggled
	Live,                 // A11y_Live
	Orientation,          // 0 horizontal, 1 vertical
	Has_Popup,            // A11y_Popup
	Aria_Current,         // A11y_Current
	Invalid,              // 0 true, 1 grammar, 2 spelling
	Sort_Direction,       // 0 ascending, 1 descending, 2 other
	Text_Direction,       // 0 ltr, 1 rtl, 2 ttb, 3 btt
	Auto_Complete,        // 0 inline, 1 list, 2 both
	List_Style,           // 0 circle, 1 disc, 2 image, 3 numeric, 4 square, 5 other
	Text_Align,           // 0 left, 1 right, 2 center, 3 justify
	Vertical_Offset,      // 0 subscript, 1 superscript

	Controls = 80, Details, Described_By, Flow_To, Labelled_By, Owns, Radio_Group,

	Active_Descendant = 90, Error_Message, In_Page_Link_Target, Member_Of, Popup_For, Next_On_Line, Previous_On_Line,

	Character_Lengths = 100,   // bytes: the UTF-8 length of each character (grapheme) of a text run's value
	Word_Starts,               // bytes: the index of the character each word starts at
	Character_Positions,       // floats: each character's start along the run, in the run's coordinate space
	Character_Widths,          // floats: each character's advance
	Text_Selection,            // ids: anchor node, anchor character index, focus node, focus character index
	Tree_Id,                   // bytes: 16, the subtree this node grafts (a document of its own: a web page, a frame)
	Color_Value,               // 0xRRGGBBAA
	Background_Color,
	Foreground_Color,
	Transform,                 // floats: 6, an affine transform [a b c d e f] for the node and its descendants
}

A11y_Toggled :: enum u8 { False, True, Mixed }
A11y_Live    :: enum u8 { Off, Polite, Assertive }
A11y_Popup   :: enum u8 { Menu, Listbox, Tree, Grid, Dialog }
A11y_Current :: enum u8 { False, True, Page, Step, Location, Date, Time }

// One node of an update (the C layout the adapter reads).
A11y_Node :: struct {
	id:           u64,
	role:         u32,
	flags:        A11y_Flags,
	actions:      A11y_Actions,
	_:            u32,
	bounds:       [4]f64,   // x0, y0, x1, y1 in physical pixels of the window's client area (Has_Bounds)
	children_off: u32,
	children_len: u32,
	props_off:    u32,
	props_len:    u32,
}

A11y_Prop :: struct {
	kind: A11y_Prop_Kind,
	len:  u32,
	a:    u64,
	f:    f64,
}

// A tree identifier: the zero one is the window's own tree; a subtree (a web page) has its own, grafted under a node
// whose Tree_Id property names it.
A11y_Tree_Id :: distinct [16]u8

// An update being written: a11y_node starts a node (the props and children written next belong to it).
A11y_Update :: struct {
	nodes:     [dynamic]A11y_Node,
	ids:       [dynamic]u64,
	props:     [dynamic]A11y_Prop,
	bytes:     [dynamic]u8,
	floats:    [dynamic]f32,
	root:      u64,
	focus:     u64,
	tree:      A11y_Tree_Id,
	tree_info: bool,   // states the tree's root (a whole tree, the first update of a subtree, a new root)
}

a11y_update_clear :: proc(u: ^A11y_Update) {
	clear(&u.nodes); clear(&u.ids); clear(&u.props); clear(&u.bytes); clear(&u.floats)
	u.root, u.focus, u.tree_info = 0, 0, false
}

a11y_update_destroy :: proc(u: ^A11y_Update) {
	delete(u.nodes); delete(u.ids); delete(u.props); delete(u.bytes); delete(u.floats)
	u^ = {}
}

// Starts a node; returns its index in u.nodes. Children and properties added next belong to it.
a11y_node :: proc(u: ^A11y_Update, id: u64, role: A11y_Role, flags: A11y_Flags = {}, actions: A11y_Actions = {}) -> int {
	append(&u.nodes, A11y_Node{id = id, role = u32(role), flags = flags, actions = actions, children_off = u32(len(u.ids)), props_off = u32(len(u.props))})
	return len(u.nodes) - 1
}

a11y_bounds :: proc(u: ^A11y_Update, x0, y0, x1, y1: f64) {
	n := &u.nodes[len(u.nodes) - 1]
	n.bounds = {x0, y0, x1, y1}
	n.flags += {.Has_Bounds}
}

// The children of the current node, in order (call once, before its properties that hold ids).
a11y_children :: proc(u: ^A11y_Update, children: []u64) {
	n := &u.nodes[len(u.nodes) - 1]
	assert(n.props_len == 0 && int(n.children_off) == len(u.ids), "a11y_children: once per node, before its id properties")
	append(&u.ids, ..children)
	n.children_len = u32(len(children))
}

@(private)
a11y_prop :: proc(u: ^A11y_Update, p: A11y_Prop) {
	append(&u.props, p)
	u.nodes[len(u.nodes) - 1].props_len += 1
}

a11y_str :: proc(u: ^A11y_Update, kind: A11y_Prop_Kind, s: string) {
	if s == "" { return }
	off := len(u.bytes)
	append(&u.bytes, s)
	a11y_prop(u, {kind = kind, len = u32(len(s)), a = u64(off)})
}

a11y_num :: proc(u: ^A11y_Update, kind: A11y_Prop_Kind, v: f64) { a11y_prop(u, {kind = kind, f = v}) }
a11y_int :: proc(u: ^A11y_Update, kind: A11y_Prop_Kind, v: u64) { a11y_prop(u, {kind = kind, a = v}) }

a11y_ids :: proc(u: ^A11y_Update, kind: A11y_Prop_Kind, ids: []u64) {
	if len(ids) == 0 { return }
	off := len(u.ids)
	append(&u.ids, ..ids)
	a11y_prop(u, {kind = kind, len = u32(len(ids)), a = u64(off)})
}

a11y_bytes :: proc(u: ^A11y_Update, kind: A11y_Prop_Kind, b: []u8) {
	off := len(u.bytes)
	append(&u.bytes, ..b)
	a11y_prop(u, {kind = kind, len = u32(len(b)), a = u64(off)})
}

a11y_floats :: proc(u: ^A11y_Update, kind: A11y_Prop_Kind, f: []f32) {
	off := len(u.floats)
	append(&u.floats, ..f)
	a11y_prop(u, {kind = kind, len = u32(len(f)), a = u64(off)})
}

a11y_selection :: proc(u: ^A11y_Update, anchor_node: u64, anchor_index: int, focus_node: u64, focus_index: int) {
	a11y_ids(u, .Text_Selection, {anchor_node, u64(anchor_index), focus_node, u64(focus_index)})
}

a11y_graft :: proc(u: ^A11y_Update, tree: A11y_Tree_Id) {
	t := tree
	a11y_bytes(u, .Tree_Id, t[:])
}

// The properties of node `i` of an update, and its children.
a11y_node_props :: proc(u: ^A11y_Update, i: int) -> []A11y_Prop {
	n := u.nodes[i]
	return u.props[n.props_off:][:n.props_len]
}
a11y_node_children :: proc(u: ^A11y_Update, i: int) -> []u64 {
	n := u.nodes[i]
	return u.ids[n.children_off:][:n.children_len]
}
a11y_prop_string :: proc(u: ^A11y_Update, p: A11y_Prop) -> string { return string(u.bytes[p.a:][:p.len]) }
a11y_prop_ids :: proc(u: ^A11y_Update, p: A11y_Prop) -> []u64 { return u.ids[p.a:][:p.len] }

// A string property of node `i` ("" when it has none).
a11y_node_string :: proc(u: ^A11y_Update, i: int, kind: A11y_Prop_Kind) -> string {
	for p in a11y_node_props(u, i) { if p.kind == kind { return a11y_prop_string(u, p) } }
	return ""
}

// What the adapter needs now.
A11y_State :: enum u8 {
	Off,           // no assistive technology reads the window: build nothing
	Full,          // one asked for the tree (or came back): send the whole tree
	Incremental,   // send the nodes that changed
}

// The result of a11y_send.
A11y_Send :: enum u8 {
	Applied,
	Inactive,   // nobody reads the window (nothing was applied)
	Invalid,    // the update breaks the tree (a node no parent reaches, a missing child): nothing applied, send a whole tree
	Failed,     // the adapter failed for good (a bug in it): the window stays unreadable
}

// What the data of a request is.
A11y_Request_Data :: enum u8 { None, Custom_Action, Value, Numeric_Value, Scroll_Unit, Scroll_Hint, Scroll_To_Point, Set_Scroll_Offset, Text_Selection }

// A request of an assistive technology (a11y_take_request): an action on a node of a tree.
A11y_Request :: struct {
	action: A11y_Action,
	data:   A11y_Request_Data,
	target: u64,
	tree:   A11y_Tree_Id,
	num:    f64,          // Custom_Action (its index), Numeric_Value, Scroll_Unit (0 item, 1 page), Scroll_Hint
	point:  [2]f64,       // Scroll_To_Point (client pixels), Set_Scroll_Offset
	value:  string,       // Value: valid until the next a11y_take_request
	sel:    [4]u64,       // Text_Selection: anchor node, anchor index, focus node, focus index
}
