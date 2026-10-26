//! gt_a11y: the toolkit's accessibility adapter. The toolkit (platform/a11y_accesskit.odin) builds a flat description
//! of the nodes that changed (GtUpdate: nodes, child ids, properties, strings) and hands it over here; this library
//! turns it into an AccessKit TreeUpdate for the platform adapter (UI Automation on Windows). Requests of assistive
//! technologies (click, focus, set value, scroll...) are queued and taken by the toolkit's loop (gt_a11y_take_action),
//! which a wake callback tells.
//!
//! Every entry point catches panics. AccessKit panics on an update that breaks the tree's invariants (a node no parent
//! reaches, a child that does not exist, a duplicate child): a mirror of the tree's structure checks each update before
//! AccessKit sees it, and an update that fails the check is refused (GT_A11Y_INVALID) instead of poisoning the adapter.

use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use accesskit::{
    Action, ActionData, ActionHandler, ActionRequest, ActivationHandler, Affine, AriaCurrent, AutoComplete, HasPopup,
    Invalid, ListStyle, Live, Node, NodeId, Orientation, Point, Rect, Role, ScrollHint, ScrollUnit, SortDirection,
    TextAlign, TextDirection, TextPosition, TextSelection, Toggled, TreeId, TreeInfo, TreeUpdate, Uuid, VerticalOffset,
};

pub const GT_A11Y_ABI: u32 = 1;

pub const GT_A11Y_APPLIED: i32 = 1;
pub const GT_A11Y_INACTIVE: i32 = 0;
pub const GT_A11Y_INVALID: i32 = -1;
pub const GT_A11Y_PANIC: i32 = -2;
pub const GT_A11Y_DEAD: i32 = -3;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GtNode {
    pub id: u64,
    pub role: u32,
    pub flags: u32,
    pub actions: u32,
    pub _pad: u32,
    pub bounds: [f64; 4],
    pub children_off: u32,
    pub children_len: u32,
    pub props_off: u32,
    pub props_len: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GtProp {
    pub kind: u32,
    pub len: u32,
    pub a: u64,
    pub f: f64,
}

#[repr(C)]
pub struct GtUpdate {
    pub nodes: *const GtNode,
    pub node_count: usize,
    pub ids: *const u64,
    pub id_count: usize,
    pub props: *const GtProp,
    pub prop_count: usize,
    pub bytes: *const u8,
    pub byte_count: usize,
    pub floats: *const f32,
    pub float_count: usize,
    pub root: u64,
    pub focus: u64,
    pub tree_id: [u8; 16],
    pub tree_info: u32, // 1: (re)state the tree's root and the toolkit's name and version
    pub _pad: u32,
    pub toolkit_name: *const u8,
    pub toolkit_name_len: usize,
    pub toolkit_version: *const u8,
    pub toolkit_version_len: usize,
}

#[repr(C)]
pub struct GtAction {
    pub action: u32,
    pub data_kind: u32,
    pub target_node: u64,
    pub tree_id: [u8; 16],
    pub num: f64,
    pub x: f64,
    pub y: f64,
    pub value: *const u8, // valid until the next gt_a11y_take_action
    pub value_len: usize,
    pub sel: [u64; 4], // anchor node, anchor index, focus node, focus index
}

// GtNode.flags
const F_HAS_BOUNDS: u32 = 1 << 24;
const F_HAS_EXPANDED: u32 = 1 << 20;
const F_EXPANDED: u32 = 1 << 21;
const F_HAS_SELECTED: u32 = 1 << 22;
const F_SELECTED: u32 = 1 << 23;

// GtProp.kind
mod prop {
    pub const LABEL: u32 = 1;
    pub const DESCRIPTION: u32 = 2;
    pub const VALUE: u32 = 3;
    pub const PLACEHOLDER: u32 = 4;
    pub const ROLE_DESCRIPTION: u32 = 5;
    pub const STATE_DESCRIPTION: u32 = 6;
    pub const KEYBOARD_SHORTCUT: u32 = 7;
    pub const ACCESS_KEY: u32 = 8;
    pub const HTML_TAG: u32 = 9;
    pub const HTML_ID: u32 = 10;
    pub const CLASS_NAME: u32 = 11;
    pub const URL: u32 = 12;
    pub const LANGUAGE: u32 = 13;
    pub const TOOLTIP: u32 = 14;
    pub const AUTHOR_ID: u32 = 15;
    pub const FONT_FAMILY: u32 = 16;
    pub const ROW_INDEX_TEXT: u32 = 17;
    pub const COLUMN_INDEX_TEXT: u32 = 18;

    pub const NUMERIC_VALUE: u32 = 30;
    pub const MIN_NUMERIC_VALUE: u32 = 31;
    pub const MAX_NUMERIC_VALUE: u32 = 32;
    pub const NUMERIC_VALUE_STEP: u32 = 33;
    pub const NUMERIC_VALUE_JUMP: u32 = 34;
    pub const SCROLL_X: u32 = 35;
    pub const SCROLL_X_MIN: u32 = 36;
    pub const SCROLL_X_MAX: u32 = 37;
    pub const SCROLL_Y: u32 = 38;
    pub const SCROLL_Y_MIN: u32 = 39;
    pub const SCROLL_Y_MAX: u32 = 40;
    pub const FONT_SIZE: u32 = 45;
    pub const FONT_WEIGHT: u32 = 46;

    pub const ROW_COUNT: u32 = 50;
    pub const COLUMN_COUNT: u32 = 51;
    pub const ROW_INDEX: u32 = 52;
    pub const COLUMN_INDEX: u32 = 53;
    pub const ROW_SPAN: u32 = 54;
    pub const COLUMN_SPAN: u32 = 55;
    pub const LEVEL: u32 = 56;
    pub const SIZE_OF_SET: u32 = 57;
    pub const POSITION_IN_SET: u32 = 58;

    pub const TOGGLED: u32 = 60;
    pub const LIVE: u32 = 61;
    pub const ORIENTATION: u32 = 62;
    pub const HAS_POPUP: u32 = 63;
    pub const ARIA_CURRENT: u32 = 64;
    pub const INVALID: u32 = 65;
    pub const SORT_DIRECTION: u32 = 66;
    pub const TEXT_DIRECTION: u32 = 67;
    pub const AUTO_COMPLETE: u32 = 68;
    pub const LIST_STYLE: u32 = 69;
    pub const TEXT_ALIGN: u32 = 70;
    pub const VERTICAL_OFFSET: u32 = 71;

    pub const CONTROLS: u32 = 80;
    pub const DETAILS: u32 = 81;
    pub const DESCRIBED_BY: u32 = 82;
    pub const FLOW_TO: u32 = 83;
    pub const LABELLED_BY: u32 = 84;
    pub const OWNS: u32 = 85;
    pub const RADIO_GROUP: u32 = 86;

    pub const ACTIVE_DESCENDANT: u32 = 90;
    pub const ERROR_MESSAGE: u32 = 91;
    pub const IN_PAGE_LINK_TARGET: u32 = 92;
    pub const MEMBER_OF: u32 = 93;
    pub const POPUP_FOR: u32 = 94;
    pub const NEXT_ON_LINE: u32 = 95;
    pub const PREVIOUS_ON_LINE: u32 = 96;

    pub const CHARACTER_LENGTHS: u32 = 100;
    pub const WORD_STARTS: u32 = 101;
    pub const CHARACTER_POSITIONS: u32 = 102;
    pub const CHARACTER_WIDTHS: u32 = 103;
    pub const TEXT_SELECTION: u32 = 104;
    pub const TREE_ID: u32 = 105;
    pub const COLOR_VALUE: u32 = 106;
    pub const BACKGROUND_COLOR: u32 = 107;
    pub const FOREGROUND_COLOR: u32 = 108;
    pub const TRANSFORM: u32 = 109;
}

const ROLE_COUNT: u32 = Role::Terminal as u32 + 1;
const ACTION_COUNT: u32 = Action::ShowContextMenu as u32 + 1;

fn role_from(code: u32) -> Role {
    if code >= ROLE_COUNT {
        return Role::Unknown;
    }
    // SAFETY: Role is #[repr(u8)] with implicit, contiguous discriminants from 0 to Terminal
    unsafe { std::mem::transmute::<u8, Role>(code as u8) }
}

fn action_from(bit: u32) -> Option<Action> {
    if bit >= ACTION_COUNT {
        return None;
    }
    // SAFETY: Action is #[repr(u8)] with implicit, contiguous discriminants from 0 to ShowContextMenu
    Some(unsafe { std::mem::transmute::<u8, Action>(bit as u8) })
}

/// The arrays of one update, bounds-checked.
struct View<'a> {
    nodes: &'a [GtNode],
    ids: &'a [u64],
    props: &'a [GtProp],
    bytes: &'a [u8],
    floats: &'a [f32],
}

unsafe fn slice<'a, T>(p: *const T, n: usize) -> &'a [T] {
    if p.is_null() || n == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, n)
    }
}

impl<'a> View<'a> {
    fn ids(&self, off: u64, len: u32) -> Option<&'a [u64]> {
        let off = usize::try_from(off).ok()?;
        self.ids.get(off..off.checked_add(len as usize)?)
    }
    fn bytes(&self, off: u64, len: u32) -> Option<&'a [u8]> {
        let off = usize::try_from(off).ok()?;
        self.bytes.get(off..off.checked_add(len as usize)?)
    }
    fn str(&self, off: u64, len: u32) -> Option<String> {
        self.bytes(off, len).map(|b| String::from_utf8_lossy(b).into_owned())
    }
    fn floats(&self, off: u64, len: u32) -> Option<&'a [f32]> {
        let off = usize::try_from(off).ok()?;
        self.floats.get(off..off.checked_add(len as usize)?)
    }
    fn children(&self, n: &GtNode) -> Option<&'a [u64]> {
        self.ids(n.children_off as u64, n.children_len)
    }
    fn node_props(&self, n: &GtNode) -> Option<&'a [GtProp]> {
        let off = n.props_off as usize;
        self.props.get(off..off.checked_add(n.props_len as usize)?)
    }
}

fn ids_vec(v: &[u64]) -> Vec<NodeId> {
    v.iter().map(|&i| NodeId(i)).collect()
}

/// Builds an AccessKit node from its flat description; None when an offset is out of bounds.
fn make_node(v: &View, n: &GtNode) -> Option<Node> {
    let mut node = Node::new(role_from(n.role));
    let f = n.flags;
    macro_rules! flag {
        ($bit:expr, $set:ident) => {
            if f & (1 << $bit) != 0 {
                node.$set();
            }
        };
    }
    flag!(0, set_hidden);
    flag!(1, set_multiselectable);
    flag!(2, set_required);
    flag!(3, set_visited);
    flag!(4, set_busy);
    flag!(5, set_live_atomic);
    flag!(6, set_modal);
    flag!(7, set_touch_transparent);
    flag!(8, set_read_only);
    flag!(9, set_disabled);
    flag!(10, set_italic);
    flag!(11, set_clips_children);
    flag!(12, set_is_line_breaking_object);
    flag!(13, set_is_page_breaking_object);
    flag!(14, set_is_spelling_error);
    flag!(15, set_is_grammar_error);
    flag!(16, set_is_search_match);
    flag!(17, set_is_suggestion);
    if f & F_HAS_EXPANDED != 0 {
        node.set_expanded(f & F_EXPANDED != 0);
    }
    if f & F_HAS_SELECTED != 0 {
        node.set_selected(f & F_SELECTED != 0);
    }
    if f & F_HAS_BOUNDS != 0 {
        let b = n.bounds;
        node.set_bounds(Rect { x0: b[0], y0: b[1], x1: b[2], y1: b[3] });
    }
    for bit in 0..ACTION_COUNT {
        if n.actions & (1 << bit) != 0 {
            if let Some(a) = action_from(bit) {
                node.add_action(a);
            }
        }
    }
    let children = v.children(n)?;
    if !children.is_empty() {
        node.set_children(ids_vec(children));
    }
    for p in v.node_props(n)? {
        let a = p.a;
        let u = a as usize;
        use prop::*;
        match p.kind {
            LABEL => node.set_label(v.str(a, p.len)?),
            DESCRIPTION => node.set_description(v.str(a, p.len)?),
            VALUE => node.set_value(v.str(a, p.len)?),
            PLACEHOLDER => node.set_placeholder(v.str(a, p.len)?),
            ROLE_DESCRIPTION => node.set_role_description(v.str(a, p.len)?),
            STATE_DESCRIPTION => node.set_state_description(v.str(a, p.len)?),
            KEYBOARD_SHORTCUT => node.set_keyboard_shortcut(v.str(a, p.len)?),
            ACCESS_KEY => node.set_access_key(v.str(a, p.len)?),
            HTML_TAG => node.set_html_tag(v.str(a, p.len)?),
            HTML_ID => node.set_html_id(v.str(a, p.len)?),
            CLASS_NAME => node.set_class_name(v.str(a, p.len)?),
            URL => node.set_url(v.str(a, p.len)?),
            LANGUAGE => node.set_language(v.str(a, p.len)?),
            TOOLTIP => node.set_tooltip(v.str(a, p.len)?),
            AUTHOR_ID => node.set_author_id(v.str(a, p.len)?),
            FONT_FAMILY => node.set_font_family(v.str(a, p.len)?),
            ROW_INDEX_TEXT => node.set_row_index_text(v.str(a, p.len)?),
            COLUMN_INDEX_TEXT => node.set_column_index_text(v.str(a, p.len)?),

            NUMERIC_VALUE => node.set_numeric_value(p.f),
            MIN_NUMERIC_VALUE => node.set_min_numeric_value(p.f),
            MAX_NUMERIC_VALUE => node.set_max_numeric_value(p.f),
            NUMERIC_VALUE_STEP => node.set_numeric_value_step(p.f),
            NUMERIC_VALUE_JUMP => node.set_numeric_value_jump(p.f),
            SCROLL_X => node.set_scroll_x(p.f),
            SCROLL_X_MIN => node.set_scroll_x_min(p.f),
            SCROLL_X_MAX => node.set_scroll_x_max(p.f),
            SCROLL_Y => node.set_scroll_y(p.f),
            SCROLL_Y_MIN => node.set_scroll_y_min(p.f),
            SCROLL_Y_MAX => node.set_scroll_y_max(p.f),
            FONT_SIZE => node.set_font_size(p.f as f32),
            FONT_WEIGHT => node.set_font_weight(p.f as f32),

            ROW_COUNT => node.set_row_count(u),
            COLUMN_COUNT => node.set_column_count(u),
            ROW_INDEX => node.set_row_index(u),
            COLUMN_INDEX => node.set_column_index(u),
            ROW_SPAN => node.set_row_span(u),
            COLUMN_SPAN => node.set_column_span(u),
            LEVEL => node.set_level(u),
            SIZE_OF_SET => node.set_size_of_set(u),
            POSITION_IN_SET => node.set_position_in_set(u),

            TOGGLED => node.set_toggled(match a {
                0 => Toggled::False,
                1 => Toggled::True,
                _ => Toggled::Mixed,
            }),
            LIVE => node.set_live(match a {
                0 => Live::Off,
                1 => Live::Polite,
                _ => Live::Assertive,
            }),
            ORIENTATION => node.set_orientation(if a == 0 { Orientation::Horizontal } else { Orientation::Vertical }),
            HAS_POPUP => node.set_has_popup(match a {
                0 => HasPopup::Menu,
                1 => HasPopup::Listbox,
                2 => HasPopup::Tree,
                3 => HasPopup::Grid,
                _ => HasPopup::Dialog,
            }),
            ARIA_CURRENT => node.set_aria_current(match a {
                0 => AriaCurrent::False,
                1 => AriaCurrent::True,
                2 => AriaCurrent::Page,
                3 => AriaCurrent::Step,
                4 => AriaCurrent::Location,
                5 => AriaCurrent::Date,
                _ => AriaCurrent::Time,
            }),
            INVALID => node.set_invalid(match a {
                0 => Invalid::True,
                1 => Invalid::Grammar,
                _ => Invalid::Spelling,
            }),
            SORT_DIRECTION => node.set_sort_direction(match a {
                0 => SortDirection::Ascending,
                1 => SortDirection::Descending,
                _ => SortDirection::Other,
            }),
            TEXT_DIRECTION => node.set_text_direction(match a {
                0 => TextDirection::LeftToRight,
                1 => TextDirection::RightToLeft,
                2 => TextDirection::TopToBottom,
                _ => TextDirection::BottomToTop,
            }),
            AUTO_COMPLETE => node.set_auto_complete(match a {
                0 => AutoComplete::Inline,
                1 => AutoComplete::List,
                _ => AutoComplete::Both,
            }),
            LIST_STYLE => node.set_list_style(match a {
                0 => ListStyle::Circle,
                1 => ListStyle::Disc,
                2 => ListStyle::Image,
                3 => ListStyle::Numeric,
                4 => ListStyle::Square,
                _ => ListStyle::Other,
            }),
            TEXT_ALIGN => node.set_text_align(match a {
                0 => TextAlign::Left,
                1 => TextAlign::Right,
                2 => TextAlign::Center,
                _ => TextAlign::Justify,
            }),
            VERTICAL_OFFSET => node.set_vertical_offset(if a == 0 {
                VerticalOffset::Subscript
            } else {
                VerticalOffset::Superscript
            }),

            CONTROLS => node.set_controls(ids_vec(v.ids(a, p.len)?)),
            DETAILS => node.set_details(ids_vec(v.ids(a, p.len)?)),
            DESCRIBED_BY => node.set_described_by(ids_vec(v.ids(a, p.len)?)),
            FLOW_TO => node.set_flow_to(ids_vec(v.ids(a, p.len)?)),
            LABELLED_BY => node.set_labelled_by(ids_vec(v.ids(a, p.len)?)),
            OWNS => node.set_owns(ids_vec(v.ids(a, p.len)?)),
            RADIO_GROUP => node.set_radio_group(ids_vec(v.ids(a, p.len)?)),

            ACTIVE_DESCENDANT => node.set_active_descendant(NodeId(a)),
            ERROR_MESSAGE => node.set_error_message(NodeId(a)),
            IN_PAGE_LINK_TARGET => node.set_in_page_link_target(NodeId(a)),
            MEMBER_OF => node.set_member_of(NodeId(a)),
            POPUP_FOR => node.set_popup_for(NodeId(a)),
            NEXT_ON_LINE => node.set_next_on_line(NodeId(a)),
            PREVIOUS_ON_LINE => node.set_previous_on_line(NodeId(a)),

            CHARACTER_LENGTHS => node.set_character_lengths(v.bytes(a, p.len)?.to_vec()),
            WORD_STARTS => node.set_word_starts(v.bytes(a, p.len)?.to_vec()),
            CHARACTER_POSITIONS => node.set_character_positions(v.floats(a, p.len)?.to_vec()),
            CHARACTER_WIDTHS => node.set_character_widths(v.floats(a, p.len)?.to_vec()),
            TEXT_SELECTION => {
                let s = v.ids(a, 4)?;
                node.set_text_selection(TextSelection {
                    anchor: TextPosition { node: NodeId(s[0]), character_index: s[1] as usize },
                    focus: TextPosition { node: NodeId(s[2]), character_index: s[3] as usize },
                });
            }
            TREE_ID => {
                let b = v.bytes(a, 16)?;
                let mut u = [0u8; 16];
                u.copy_from_slice(b);
                node.set_tree_id(TreeId(Uuid::from_bytes(u)));
            }
            COLOR_VALUE => node.set_color_value(color(a)),
            BACKGROUND_COLOR => node.set_background_color(color(a)),
            FOREGROUND_COLOR => node.set_foreground_color(color(a)),
            TRANSFORM => {
                let t = v.floats(a, 6)?;
                node.set_transform(Affine::new([
                    t[0] as f64, t[1] as f64, t[2] as f64, t[3] as f64, t[4] as f64, t[5] as f64,
                ]));
            }
            _ => {} // a property this version does not know: ignored (a newer toolkit, an older library)
        }
    }
    // A text run AccessKit can read: a value (empty if need be), and lengths that cover it exactly (its text code
    // unwraps the one and indexes by the other). Lengths that do not add up are made again, one per character.
    if node.role() == Role::TextRun {
        let value = node.value().map(|v| v.to_string()).unwrap_or_default();
        if node.value().is_none() {
            node.set_value(String::new());
        }
        let sum: usize = node.character_lengths().iter().map(|&l| l as usize).sum();
        if sum != value.len() || node.character_lengths().iter().any(|&l| l == 0) {
            let lens: Vec<u8> = value.chars().map(|c| c.len_utf8() as u8).collect();
            let n = lens.len();
            node.set_character_lengths(lens);
            if node.character_positions().map_or(false, |p| p.len() != n) {
                node.clear_character_positions();
            }
            if node.character_widths().map_or(false, |w| w.len() != n) {
                node.clear_character_widths();
            }
            node.clear_word_starts();
        }
        let n = node.character_lengths().len();
        if node.word_starts().iter().any(|&w| w as usize >= n.max(1)) {
            node.clear_word_starts();
        }
    }
    Some(node)
}

fn color(rgba: u64) -> accesskit::Color {
    accesskit::Color {
        red: (rgba >> 24) as u8,
        green: (rgba >> 16) as u8,
        blue: (rgba >> 8) as u8,
        alpha: rgba as u8,
    }
}

/// The structure of the trees AccessKit holds (children of every node, the graft nodes, roots and focus), to refuse
/// an update AccessKit would panic on.
#[derive(Default)]
struct Mirror {
    trees: HashMap<TreeId, MirrorTree>,
    graft_of: HashMap<TreeId, (TreeId, u64)>, // subtree -> (tree, graft node)
}

#[derive(Default, Clone)]
struct MirrorTree {
    root: Option<u64>,
    children: HashMap<u64, Vec<u64>>,
    grafts: HashMap<u64, TreeId>, // graft node -> subtree
}

impl Mirror {
    /// Checks an update the way accesskit_consumer applies it; on success returns the tree as it will be.
    fn check(&self, tree_id: TreeId, root: Option<u64>, focus: u64, nodes: &[(u64, Vec<u64>, Option<TreeId>)]) -> Option<MirrorTree> {
        let old = self.trees.get(&tree_id);
        if tree_id != TreeId::ROOT {
            if old.is_none() && root.is_none() {
                return None; // the first update of a subtree states its root
            }
            if root.is_some() && !self.graft_of.contains_key(&tree_id) {
                return None; // no graft node for it yet
            }
        }
        let mut t = old.cloned().unwrap_or_default();
        let new_root = root.or(t.root)?;
        let mut seen = HashSet::new();
        let mut unreachable = HashSet::new();
        if let (Some(r), Some(old_root)) = (root, t.root) {
            if r != old_root {
                unreachable.insert(old_root);
            }
        }
        let in_update: HashSet<u64> = nodes.iter().map(|n| n.0).collect();
        if in_update.len() != nodes.len() {
            return None; // a node twice in one update
        }
        for (_, children, graft) in nodes {
            if graft.is_some() && !children.is_empty() {
                return None;
            }
            for c in children {
                if !seen.insert(*c) {
                    return None; // duplicate child
                }
                if !t.children.contains_key(c) && !in_update.contains(c) {
                    return None; // a child that is nowhere
                }
            }
        }
        for (id, _, _) in nodes {
            if *id != new_root && !t.children.contains_key(id) && !seen.contains(id) {
                return None; // a new node no parent reaches
            }
        }
        for (id, _, _) in nodes {
            unreachable.remove(id);
            if let Some(old_children) = t.children.get(id) {
                for c in old_children {
                    if !seen.contains(c) {
                        unreachable.insert(*c);
                    }
                }
            }
        }
        for (id, children, graft) in nodes {
            t.children.insert(*id, children.clone());
            match graft {
                Some(g) => {
                    t.grafts.insert(*id, *g);
                }
                None => {
                    t.grafts.remove(id);
                }
            }
        }
        for u in unreachable {
            if seen.contains(&u) || u == new_root {
                continue;
            }
            let mut stack = vec![u];
            while let Some(id) = stack.pop() {
                if let Some(ch) = t.children.remove(&id) {
                    for c in ch {
                        if !seen.contains(&c) && c != new_root {
                            stack.push(c);
                        }
                    }
                }
                t.grafts.remove(&id);
            }
        }
        t.root = Some(new_root);
        if !t.children.contains_key(&new_root) || !t.children.contains_key(&focus) {
            return None;
        }
        Some(t)
    }

    fn commit(&mut self, tree_id: TreeId, t: MirrorTree) {
        // grafts: the subtrees whose graft node went away go with it
        let old_grafts: HashSet<TreeId> = self.trees.get(&tree_id).map(|o| o.grafts.values().copied().collect()).unwrap_or_default();
        let new_grafts: HashSet<TreeId> = t.grafts.values().copied().collect();
        for (node, sub) in &t.grafts {
            self.graft_of.insert(*sub, (tree_id, *node));
        }
        self.trees.insert(tree_id, t);
        let mut gone: Vec<TreeId> = old_grafts.difference(&new_grafts).copied().collect();
        while let Some(sub) = gone.pop() {
            self.graft_of.remove(&sub);
            if let Some(st) = self.trees.remove(&sub) {
                gone.extend(st.grafts.values().copied());
            }
        }
    }
}

struct Shared {
    actions: Mutex<VecDeque<ActionRequest>>,
    requested: std::sync::atomic::AtomicBool, // an assistive technology asked for the tree: send a full one
    wake: extern "C" fn(*mut c_void),
    wake_user: usize,
}

impl Shared {
    fn wake(&self) {
        (self.wake)(self.wake_user as *mut c_void);
    }
}

struct Handler(Arc<Shared>);

impl ActionHandler for Handler {
    fn do_action(&mut self, request: ActionRequest) {
        if let Ok(mut q) = self.0.actions.lock() {
            if q.len() < 1024 {
                q.push_back(request);
            }
        }
        self.0.wake();
    }
}

impl ActivationHandler for Handler {
    fn request_initial_tree(&mut self) -> Option<TreeUpdate> {
        // the tree is built by the toolkit's next frame (the adapter answers with a placeholder until then)
        self.0.requested.store(true, std::sync::atomic::Ordering::SeqCst);
        self.0.wake();
        None
    }
}

pub struct GtAdapter {
    #[cfg(windows)]
    adapter: Mutex<accesskit_windows::Adapter>,
    shared: Arc<Shared>,
    mirror: Mutex<Mirror>,
    sent_any: std::sync::atomic::AtomicBool,
    dead: std::sync::atomic::AtomicBool,
    last_value: Mutex<String>,
}

fn guard<T>(dead: Option<&std::sync::atomic::AtomicBool>, fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            if let Some(d) = dead {
                d.store(true, std::sync::atomic::Ordering::SeqCst);
            }
            fallback
        }
    }
}

/// The ABI version (GT_A11Y_ABI): the toolkit refuses a library of another one.
#[no_mangle]
pub extern "C" fn gt_a11y_abi() -> u32 {
    GT_A11Y_ABI
}

/// Makes the adapter of a window (an HWND on Windows). Not while handling WM_GETOBJECT. `wake` is called (from any
/// thread) when the toolkit's loop has something to do: an assistive technology asked for the tree, or for an action.
#[no_mangle]
pub extern "C" fn gt_a11y_new(window: *mut c_void, focused: i32, wake: extern "C" fn(*mut c_void), wake_user: *mut c_void) -> *mut GtAdapter {
    guard(None, std::ptr::null_mut(), || {
        let shared = Arc::new(Shared {
            actions: Mutex::new(VecDeque::new()),
            requested: std::sync::atomic::AtomicBool::new(false),
            wake,
            wake_user: wake_user as usize,
        });
        #[cfg(windows)]
        let adapter = accesskit_windows::Adapter::new(accesskit_windows::HWND(window), focused != 0, Handler(Arc::clone(&shared)));
        #[cfg(not(windows))]
        let _ = (window, focused);
        Box::into_raw(Box::new(GtAdapter {
            #[cfg(windows)]
            adapter: Mutex::new(adapter),
            shared,
            mirror: Mutex::new(Mirror::default()),
            sent_any: std::sync::atomic::AtomicBool::new(false),
            dead: std::sync::atomic::AtomicBool::new(false),
            last_value: Mutex::new(String::new()),
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn gt_a11y_free(a: *mut GtAdapter) {
    if a.is_null() {
        return;
    }
    guard(None, (), || drop(Box::from_raw(a)));
}

/// WM_GETOBJECT: 1 and *result set when the adapter answered (return *result from the window procedure), 0 when the
/// window procedure passes the message on to DefWindowProc.
#[no_mangle]
pub unsafe extern "C" fn gt_a11y_wm_getobject(a: *mut GtAdapter, wparam: usize, lparam: isize, result: *mut isize) -> i32 {
    let Some(a) = a.as_ref() else { return 0 };
    if a.dead.load(std::sync::atomic::Ordering::SeqCst) || result.is_null() {
        return 0;
    }
    #[cfg(windows)]
    {
        guard(Some(&a.dead), 0, || {
            let mut handler = Handler(Arc::clone(&a.shared));
            // the lock is released before the conversion into an LRESULT (UiaReturnRawElementProvider may send a nested
            // WM_GETOBJECT)
            let r = {
                let Ok(mut ad) = a.adapter.lock() else { return 0 };
                ad.handle_wm_getobject(accesskit_windows::WPARAM(wparam), accesskit_windows::LPARAM(lparam), &mut handler)
            };
            match r {
                Some(r) => {
                    let lr: accesskit_windows::LRESULT = r.into();
                    *result = lr.0;
                    1
                }
                None => 0,
            }
        })
    }
    #[cfg(not(windows))]
    {
        let _ = (wparam, lparam);
        0
    }
}

/// 0: no assistive technology asked for the tree yet (build nothing); 1: one asked since the last update (send the
/// whole tree); 2: active (send what changed).
#[no_mangle]
pub unsafe extern "C" fn gt_a11y_state(a: *const GtAdapter) -> i32 {
    let Some(a) = a.as_ref() else { return 0 };
    if a.dead.load(std::sync::atomic::Ordering::SeqCst) {
        return 0;
    }
    if a.shared.requested.load(std::sync::atomic::Ordering::SeqCst) {
        return 1;
    }
    if a.sent_any.load(std::sync::atomic::Ordering::SeqCst) { 2 } else { 0 }
}

/// Applies an update (GT_A11Y_APPLIED), raising the events it makes; GT_A11Y_INACTIVE when no assistive technology
/// asked for the tree; GT_A11Y_INVALID when the update breaks the tree (nothing applied: send the whole tree again).
#[no_mangle]
pub unsafe extern "C" fn gt_a11y_update(a: *mut GtAdapter, u: *const GtUpdate) -> i32 {
    let Some(a) = a.as_ref() else { return GT_A11Y_DEAD };
    let Some(u) = u.as_ref() else { return GT_A11Y_INVALID };
    if a.dead.load(std::sync::atomic::Ordering::SeqCst) {
        return GT_A11Y_DEAD;
    }
    guard(Some(&a.dead), GT_A11Y_PANIC, || {
        let v = View {
            nodes: slice(u.nodes, u.node_count),
            ids: slice(u.ids, u.id_count),
            props: slice(u.props, u.prop_count),
            bytes: slice(u.bytes, u.byte_count),
            floats: slice(u.floats, u.float_count),
        };
        let tree_id = TreeId(Uuid::from_bytes(u.tree_id));
        let mut nodes = Vec::with_capacity(v.nodes.len());
        let mut shape = Vec::with_capacity(v.nodes.len());
        for n in v.nodes {
            let Some(node) = make_node(&v, n) else { return GT_A11Y_INVALID };
            shape.push((n.id, node.children().iter().map(|c| c.0).collect::<Vec<u64>>(), node.tree_id()));
            nodes.push((NodeId(n.id), node));
        }
        // a text selection points into the node's own text runs, within their characters (AccessKit's text code
        // indexes by it when a screen reader asks); one that does not is dropped
        let runs: HashMap<u64, usize> = nodes
            .iter()
            .filter(|(_, n)| n.role() == Role::TextRun)
            .map(|(id, n)| (id.0, n.character_lengths().len()))
            .collect();
        for (_, node) in nodes.iter_mut() {
            if let Some(sel) = node.text_selection().copied() {
                let ok = |p: TextPosition| {
                    node.children().contains(&p.node) && runs.get(&p.node.0).map_or(true, |&len| p.character_index <= len)
                };
                if !ok(sel.anchor) || !ok(sel.focus) {
                    node.clear_text_selection();
                }
            }
        }
        let tree = if u.tree_info != 0 {
            let mut info = TreeInfo::new(NodeId(u.root));
            info.toolkit_name = Some(String::from_utf8_lossy(slice(u.toolkit_name, u.toolkit_name_len)).into_owned());
            info.toolkit_version = Some(String::from_utf8_lossy(slice(u.toolkit_version, u.toolkit_version_len)).into_owned());
            Some(info)
        } else {
            None
        };
        let checked = {
            let Ok(m) = a.mirror.lock() else { return GT_A11Y_DEAD };
            m.check(tree_id, tree.as_ref().map(|t| t.root.0), u.focus, &shape)
        };
        let Some(next) = checked else { return GT_A11Y_INVALID };
        let update = TreeUpdate { nodes, tree, tree_id, focus: NodeId(u.focus) };
        #[cfg(windows)]
        {
            let events = {
                let Ok(mut ad) = a.adapter.lock() else { return GT_A11Y_DEAD };
                let mut update = Some(update);
                let ev = ad.update_if_active(|| update.take().unwrap());
                if update.is_some() {
                    return GT_A11Y_INACTIVE; // (not active: the factory was not called)
                }
                ev
            };
            a.mirror.lock().map(|mut m| m.commit(tree_id, next)).ok();
            a.shared.requested.store(false, std::sync::atomic::Ordering::SeqCst);
            a.sent_any.store(true, std::sync::atomic::Ordering::SeqCst);
            if let Some(ev) = events {
                ev.raise();
            }
            GT_A11Y_APPLIED
        }
        #[cfg(not(windows))]
        {
            let _ = (update, next);
            GT_A11Y_INACTIVE
        }
    })
}

/// The window gained or lost the keyboard focus.
#[no_mangle]
pub unsafe extern "C" fn gt_a11y_window_focus(a: *mut GtAdapter, focused: i32) {
    let Some(a) = a.as_ref() else { return };
    if a.dead.load(std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    #[cfg(windows)]
    guard(Some(&a.dead), (), || {
        let events = {
            let Ok(mut ad) = a.adapter.lock() else { return };
            ad.update_window_focus_state(focused != 0)
        };
        if let Some(ev) = events {
            ev.raise();
        }
    });
    #[cfg(not(windows))]
    let _ = focused;
}

/// Takes the oldest action an assistive technology asked for: 1 and *out filled, 0 when there is none. out.value stays
/// valid until the next call.
#[no_mangle]
pub unsafe extern "C" fn gt_a11y_take_action(a: *mut GtAdapter, out: *mut GtAction) -> i32 {
    let Some(a) = a.as_ref() else { return 0 };
    let Some(out) = out.as_mut() else { return 0 };
    guard(None, 0, || {
        let req = {
            let Ok(mut q) = a.shared.actions.lock() else { return 0 };
            match q.pop_front() {
                Some(r) => r,
                None => return 0,
            }
        };
        let Ok(mut last) = a.last_value.lock() else { return 0 };
        last.clear();
        *out = GtAction {
            action: req.action as u32,
            data_kind: 0,
            target_node: req.target_node.0,
            tree_id: *req.target_tree.0.as_bytes(),
            num: 0.0,
            x: 0.0,
            y: 0.0,
            value: std::ptr::null(),
            value_len: 0,
            sel: [0; 4],
        };
        match req.data {
            None => {}
            Some(ActionData::CustomAction(i)) => {
                out.data_kind = 1;
                out.num = i as f64;
            }
            Some(ActionData::Value(s)) => {
                out.data_kind = 2;
                last.push_str(&s);
                out.value = last.as_ptr();
                out.value_len = last.len();
            }
            Some(ActionData::NumericValue(n)) => {
                out.data_kind = 3;
                out.num = n;
            }
            Some(ActionData::ScrollUnit(unit)) => {
                out.data_kind = 4;
                out.num = match unit {
                    ScrollUnit::Item => 0.0,
                    ScrollUnit::Page => 1.0,
                };
            }
            Some(ActionData::ScrollHint(h)) => {
                out.data_kind = 5;
                out.num = match h {
                    ScrollHint::TopLeft => 0.0,
                    ScrollHint::BottomRight => 1.0,
                    ScrollHint::TopEdge => 2.0,
                    ScrollHint::BottomEdge => 3.0,
                    ScrollHint::LeftEdge => 4.0,
                    ScrollHint::RightEdge => 5.0,
                };
            }
            Some(ActionData::ScrollToPoint(Point { x, y })) => {
                out.data_kind = 6;
                out.x = x;
                out.y = y;
            }
            Some(ActionData::SetScrollOffset(Point { x, y })) => {
                out.data_kind = 7;
                out.x = x;
                out.y = y;
            }
            Some(ActionData::SetTextSelection(s)) => {
                out.data_kind = 8;
                out.sel = [s.anchor.node.0, s.anchor.character_index as u64, s.focus.node.0, s.focus.character_index as u64];
            }
        }
        1
    })
}
