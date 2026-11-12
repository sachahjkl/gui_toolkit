#+build windows
package tk_h264

// NVIDIA's driver libraries, by LoadLibrary: its installer puts both in System32.

import win "core:sys/windows"

// nvcuda.dll and nvEncodeAPI64.dll, with the calls nvenc_load takes; false (nothing kept loaded) when either is missing.
@(private)
nvenc_libraries_open :: proc(c: ^CUDA_Library, entry: ^NV_Entry) -> bool {
	cuda_library := win.LoadLibraryW(win.L("nvcuda.dll"))
	if cuda_library == nil { return false }
	encode_library := win.LoadLibraryW(win.L("nvEncodeAPI64.dll"))
	if encode_library == nil { win.FreeLibrary(cuda_library); return false }
	c.init = auto_cast win.GetProcAddress(cuda_library, "cuInit")
	c.device_get_count = auto_cast win.GetProcAddress(cuda_library, "cuDeviceGetCount")
	c.device_get = auto_cast win.GetProcAddress(cuda_library, "cuDeviceGet")
	c.ctx_create = auto_cast win.GetProcAddress(cuda_library, "cuCtxCreate_v2")
	c.ctx_destroy = auto_cast win.GetProcAddress(cuda_library, "cuCtxDestroy_v2")
	c.ctx_push_current = auto_cast win.GetProcAddress(cuda_library, "cuCtxPushCurrent_v2")
	c.ctx_pop_current = auto_cast win.GetProcAddress(cuda_library, "cuCtxPopCurrent_v2")
	entry.get_max_supported_version = auto_cast win.GetProcAddress(encode_library, "NvEncodeAPIGetMaxSupportedVersion")
	entry.create_instance = auto_cast win.GetProcAddress(encode_library, "NvEncodeAPICreateInstance")
	if c.init == nil || c.device_get_count == nil || c.device_get == nil || c.ctx_create == nil || c.ctx_destroy == nil ||
	   c.ctx_push_current == nil || c.ctx_pop_current == nil || entry.get_max_supported_version == nil ||
	   entry.create_instance == nil {
		c^, entry^ = {}, {}
		win.FreeLibrary(encode_library)
		win.FreeLibrary(cuda_library)
		return false
	}
	return true
}
