package render

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

// The graphics device made early, on a thread of its own. The first device of a process is the longest step of a
// renderer's start: it loads the graphics driver (Direct3D 11, measured: 416 to 480 ms the first time in a process, 25 ms
// a second time; the shaders and buffers take about 1 ms, the swap chain 5 to 60). A program that knows it will render
// calls preload_device as early as it can and does the rest of its start meanwhile; the next init or init_offscreen that
// asks for that kind of device takes it, waiting for the thread if it has not finished. Only the device: the swap chain or
// the wgpu surface needs the window, and init makes it as before. On wgpu the instance, adapter and device are made
// without a surface; init then makes the window's surface on that instance and checks the adapter can present to it
// (else it lets the device go and makes its own as before).
//
//   preload_device(warp)        Not_Started -> Creating; the thread then sets Ready or Failed
//   init / init_offscreen       wait for the thread; Ready and of the kind asked for: the renderer takes the device
//                               (otherwise it is released); in every case the state is Not_Started again
//   release_preloaded_device    a program that will not render after all lets it go

Device_Preload_State :: enum i32 {
	Not_Started,   // nothing asked for, or what was made has been taken or released
	Creating,      // the thread is making the device
	Ready,         // made: the next init of its kind takes it
	Failed,        // the thread could not make it: init makes its own (and meets the same failure, or falls back to WARP)
}

@(private)
Device_Preload :: struct {
	lock:   sync.Mutex,             // preload_device, take and release: one at a time (renderers may start on several threads)
	state:  Device_Preload_State,   // atomic: the thread writes Ready or Failed, readers need no lock
	warp:   bool,                   // the software rasterizer was asked for
	worker: ^thread.Thread,
	began:  time.Tick,
	held:   Renderer,               // where the thread makes the device: device and ctx (Direct3D 11), wg (wgpu)
	done:   proc(user: rawptr),     // preload_device's: called by the thread once the device is made (or failed)
	user:   rawptr,
}

@(private)
preload: Device_Preload

// Starts making the device on a thread of its own: `warp`, the software rasterizer (as init_offscreen's). False: one is
// already being made or waits to be taken, or no thread could be started (init then makes the device as usual).
// `done`, when given, is called on that thread once the state is Ready or Failed: a program's loop that sleeps until
// an event wakes itself with it (platform.wake), then opens its windows while the device waits.
preload_device :: proc(warp := false, done: proc(user: rawptr) = nil, user: rawptr = nil) -> bool {
	sync.guard(&preload.lock)
	if sync.atomic_load(&preload.state) != .Not_Started { return false }
	preload.warp = warp
	preload.done, preload.user = done, user
	preload.began = time.tick_now()
	when USE_WGPU { preload.held.wg.shared = new(Wgpu_Shared) }   // (the caller's allocator, as wgpu_create_device's)
	sync.atomic_store(&preload.state, .Creating)
	preload.worker = thread.create_and_start(make_preloaded_device)
	if preload.worker == nil {
		discard_held()
		sync.atomic_store(&preload.state, .Not_Started)
		return false
	}
	return true
}

// Where the device made early is now.
device_preload_state :: proc() -> Device_Preload_State { return sync.atomic_load(&preload.state) }

// Lets the device made early go (waiting for the thread first): for a program that ends up not rendering.
release_preloaded_device :: proc() {
	sync.guard(&preload.lock)
	if sync.atomic_load(&preload.state) == .Not_Started { return }
	join_worker()
	discard_held()
	sync.atomic_store(&preload.state, .Not_Started)
}

// The device made early, moved into `r` when it is of the kind asked for (`warp`). False: there is none (or it failed, or
// is of the other kind: it is released), and the caller makes its own.
@(private)
take_preloaded_device :: proc(r: ^Renderer, warp: bool) -> bool {
	sync.guard(&preload.lock)
	if sync.atomic_load(&preload.state) == .Not_Started { return false }
	waited := time.tick_now()
	join_worker()
	state := sync.atomic_load(&preload.state)
	took := state == .Ready && preload.warp == warp
	if took {
		when USE_WGPU {
			r.wg = preload.held.wg
			r.wg.t_device = time.duration_milliseconds(time.tick_since(waited))   // (what this init paid for it)
		} else {
			r.device, r.ctx = preload.held.device, preload.held.ctx
		}
		preload.held = {}
	} else {
		discard_held()
	}
	sync.atomic_store(&preload.state, .Not_Started)
	if render_trace() {
		fmt.eprintfln("render: device made early (%v, %s): waited %.1f ms for it, %.1f ms after it was asked for, %.0f ms after the process started",
			state, took ? "taken" : "not taken", time.duration_milliseconds(time.tick_since(waited)), time.duration_milliseconds(time.tick_since(preload.began)), process_uptime_ms())
	}
	return took
}

@(private = "file")
make_preloaded_device :: proc() {
	ok: bool
	when USE_WGPU {
		ok = wgpu_create_device_here(&preload.held, {}, preload.warp)   // (no surface: the window's is made by init)
	} else {
		ok = create_device(&preload.held, preload.warp ? .WARP : .HARDWARE)
	}
	sync.atomic_store(&preload.state, ok ? .Ready : .Failed)
	if preload.done != nil { preload.done(preload.user) }
}

@(private = "file")
join_worker :: proc() {
	if preload.worker == nil { return }
	thread.join(preload.worker)
	thread.destroy(preload.worker)
	preload.worker = nil
}

// What the thread made, released (the whole of it, or what it made before it failed).
@(private = "file")
discard_held :: proc() {
	when USE_WGPU {
		wgpu_release_device(&preload.held)
		if preload.held.wg.shared != nil { free(preload.held.wg.shared) }
	} else {
		if preload.held.ctx != nil { preload.held.ctx->Release() }
		if preload.held.device != nil { preload.held.device->Release() }
	}
	preload.held = {}
}
