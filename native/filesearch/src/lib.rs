//! The toolkit's file search engine (src/filesearch, src/md/features/file-search.md): indexes directory trees on
//! background threads, watches changes, ranks by frecency (LMDB), and matches names with typo tolerance via fff-search.
//! Every entry point catches panics so a fault never crashes the host program.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use fff_search::dbs::frecency::FrecencyTracker;
use fff_search::file_picker::{FilePicker, FilePickerOptions, FuzzySearchOptions};
use fff_search::types::{MixedItemRef, PaginationArgs};
use fff_search::{FFFMode, QueryParser, SharedFilePicker, SharedFrecency};

pub const OK: i32 = 0;
pub const INVALID_PATH: i32 = 1;
pub const FAILED: i32 = 2;

const FLAG_WATCH: u32 = 1 << 0;
const FLAG_FOLLOW_SYMLINKS: u32 = 1 << 1;
const FLAG_ALLOW_HOME: u32 = 1 << 2;

struct Entry {
    picker: SharedFilePicker,
    frecency: SharedFrecency,
    base_path: PathBuf,
}

struct Indices {
    next: u32,
    open: HashMap<u32, Entry>,
}

fn indices() -> &'static Mutex<Indices> {
    static INDICES: OnceLock<Mutex<Indices>> = OnceLock::new();
    INDICES.get_or_init(|| Mutex::new(Indices { next: 0, open: HashMap::new() }))
}

fn get_entry(id: u32) -> Option<(SharedFilePicker, SharedFrecency, PathBuf)> {
    let guard = indices().lock().ok()?;
    let e = guard.open.get(&id)?;
    Some((e.picker.clone(), e.frecency.clone(), e.base_path.clone()))
}

unsafe fn bytes_to_str<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if len == 0 {
        return Some("");
    }
    if ptr.is_null() {
        return None;
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}

#[repr(C)]
pub struct GtFilesearchOpen {
    pub root: *const u8,
    pub root_len: usize,
    pub frecency_dir: *const u8,
    pub frecency_dir_len: usize,
    pub flags: u32,
}

#[no_mangle]
pub extern "C" fn gt_filesearch_open(opts: *const GtFilesearchOpen, out_id: *mut u32) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if opts.is_null() || out_id.is_null() {
            return FAILED;
        }
        let o = unsafe { &*opts };
        let Some(root_str) = (unsafe { bytes_to_str(o.root, o.root_len) }) else {
            return INVALID_PATH;
        };
        if root_str.is_empty() {
            return INVALID_PATH;
        }
        let base_path = PathBuf::from(root_str);
        if !base_path.is_dir() {
            return INVALID_PATH;
        }
        let frecency_str = unsafe { bytes_to_str(o.frecency_dir, o.frecency_dir_len) }.unwrap_or("");

        let shared_picker = SharedFilePicker::default();
        let shared_frecency = SharedFrecency::default();
        if !frecency_str.is_empty() {
            let db_dir = PathBuf::from(frecency_str);
            if std::fs::create_dir_all(&db_dir).is_ok() {
                if let Ok(tracker) = FrecencyTracker::open(&db_dir) {
                    let _ = shared_frecency.init(tracker);
                }
            }
        }

        let picker_opts = FilePickerOptions {
            base_path: root_str.to_string(),
            enable_mmap_cache: false,
            enable_content_indexing: false,
            mode: FFFMode::Ai,
            cache_budget: None,
            watch: (o.flags & FLAG_WATCH) != 0,
            follow_symlinks: (o.flags & FLAG_FOLLOW_SYMLINKS) != 0,
            enable_fs_root_scanning: false,
            enable_home_dir_scanning: (o.flags & FLAG_ALLOW_HOME) != 0,
            ..Default::default()
        };
        if FilePicker::new_with_shared_state(
            shared_picker.clone(),
            shared_frecency.clone(),
            picker_opts,
        )
        .is_err()
        {
            return FAILED;
        }

        let Ok(mut map) = indices().lock() else {
            return FAILED;
        };
        map.next = map.next.wrapping_add(1);
        if map.next == 0 {
            map.next = 1;
        }
        let id = map.next;
        map.open.insert(
            id,
            Entry {
                picker: shared_picker,
                frecency: shared_frecency,
                base_path,
            },
        );
        unsafe {
            *out_id = id;
        }
        OK
    }))
    .unwrap_or(FAILED)
}

#[no_mangle]
pub extern "C" fn gt_filesearch_close(id: u32) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let entry = {
            let Ok(mut map) = indices().lock() else {
                return;
            };
            map.open.remove(&id)
        };
        if let Some(e) = entry {
            if let Ok(mut guard) = e.picker.write() {
                if let Some(picker) = guard.as_mut() {
                    picker.stop_background_monitor();
                }
                *guard = None;
            }
        }
    }));
}

#[no_mangle]
pub extern "C" fn gt_filesearch_wait(id: u32, timeout_ms: u32) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some((picker, _, _)) = get_entry(id) else {
            return false;
        };
        picker.wait_for_scan(Duration::from_millis(timeout_ms as u64))
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn gt_filesearch_state(
    id: u32,
    out_scanning: *mut u8,
    out_watching: *mut u8,
    out_scanned: *mut usize,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some((shared_picker, _, _)) = get_entry(id) else {
            return false;
        };
        let Ok(guard) = shared_picker.read() else {
            return false;
        };
        let Some(picker) = guard.as_ref() else {
            return false;
        };
        let prog = picker.get_scan_progress();
        unsafe {
            if !out_scanning.is_null() {
                *out_scanning = if prog.is_scanning { 1 } else { 0 };
            }
            if !out_watching.is_null() {
                *out_watching = if prog.is_watcher_ready { 1 } else { 0 };
            }
            if !out_scanned.is_null() {
                *out_scanned = prog.scanned_files_count;
            }
        }
        true
    }))
    .unwrap_or(false)
}

fn push_u16(buf: &mut Vec<u8>, v: u16) {
    buf.extend_from_slice(&v.to_le_bytes());
}
fn push_u32(buf: &mut Vec<u8>, v: u32) {
    buf.extend_from_slice(&v.to_le_bytes());
}
fn push_i32(buf: &mut Vec<u8>, v: i32) {
    buf.extend_from_slice(&v.to_le_bytes());
}

#[no_mangle]
pub extern "C" fn gt_filesearch_search(
    id: u32,
    query: *const u8,
    query_len: usize,
    offset: usize,
    limit: usize,
    dirs: u8,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return FAILED;
        }
        let Some((shared_picker, _, _)) = get_entry(id) else {
            return FAILED;
        };
        let Some(q_str) = (unsafe { bytes_to_str(query, query_len) }) else {
            return FAILED;
        };
        let Ok(guard) = shared_picker.read() else {
            return FAILED;
        };
        let Some(picker) = guard.as_ref() else {
            return FAILED;
        };

        let parser = QueryParser::default();
        let parsed = parser.parse(q_str);
        let lim = if limit > 0 { limit } else { 50 };
        let opts = FuzzySearchOptions {
            max_threads: 0,
            current_file: None,
            project_path: None,
            combo_boost_score_multiplier: 100,
            min_combo_count: 3,
            pagination: PaginationArgs { offset, limit: lim },
        };

        let mut buf = Vec::with_capacity(4096);
        if dirs != 0 {
            let res = picker.fuzzy_search_mixed(&parsed, None, opts);
            push_u32(&mut buf, res.total_matched.min(u32::MAX as usize) as u32);
            push_u32(&mut buf, (res.total_files + res.total_dirs).min(u32::MAX as usize) as u32);
            push_u32(&mut buf, res.items.len().min(u32::MAX as usize) as u32);
            for (item, score) in res.items.iter().zip(res.scores.iter()) {
                let (is_dir, rel) = match item {
                    MixedItemRef::File(f) => (0u8, f.relative_path(picker)),
                    MixedItemRef::Dir(d) => (1u8, d.relative_path(picker)),
                };
                buf.push(is_dir);
                push_i32(&mut buf, score.total);
                let pb = rel.as_bytes();
                push_u32(&mut buf, pb.len().min(u32::MAX as usize) as u32);
                buf.extend_from_slice(pb);
                push_u16(&mut buf, 0);
            }
        } else {
            let res = picker.fuzzy_search(&parsed, None, opts);
            push_u32(&mut buf, res.total_matched.min(u32::MAX as usize) as u32);
            push_u32(&mut buf, res.total_files.min(u32::MAX as usize) as u32);
            push_u32(&mut buf, res.items.len().min(u32::MAX as usize) as u32);
            for (i, item) in res.items.iter().enumerate() {
                let score = res.scores.get(i).map(|s| s.total).unwrap_or(0);
                let rel = item.relative_path(picker);
                buf.push(0u8);
                push_i32(&mut buf, score);
                let pb = rel.as_bytes();
                push_u32(&mut buf, pb.len().min(u32::MAX as usize) as u32);
                buf.extend_from_slice(pb);
                let ranges = res.match_byte_offsets.get(i).map(|v| v.as_slice()).unwrap_or(&[]);
                let rc = ranges.len().min(u16::MAX as usize);
                push_u16(&mut buf, rc as u16);
                for &(start, end) in &ranges[..rc] {
                    push_u32(&mut buf, start);
                    push_u32(&mut buf, end);
                }
            }
        }

        let boxed = buf.into_boxed_slice();
        let len = boxed.len();
        let ptr = Box::into_raw(boxed) as *mut u8;
        unsafe {
            *out_ptr = ptr;
            *out_len = len;
        }
        OK
    }))
    .unwrap_or(FAILED)
}

#[no_mangle]
pub extern "C" fn gt_filesearch_note_opened(id: u32, path: *const u8, path_len: usize) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some((shared_picker, shared_frecency, base_path)) = get_entry(id) else {
            return false;
        };
        let Some(p_str) = (unsafe { bytes_to_str(path, path_len) }) else {
            return false;
        };
        if p_str.is_empty() {
            return false;
        }
        let p = Path::new(p_str);
        let full = if p.is_absolute() { p.to_path_buf() } else { base_path.join(p) };
        let Ok(fguard) = shared_frecency.read() else {
            return false;
        };
        let Some(tracker) = fguard.as_ref() else {
            return false;
        };
        if tracker.track_access(&full).is_err() {
            return false;
        }
        if let Ok(mut pguard) = shared_picker.write() {
            if let Some(picker) = pguard.as_mut() {
                let _ = picker.update_single_file_frecency(&full, tracker);
            }
        }
        true
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn gt_filesearch_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    }));
}
