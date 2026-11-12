#+build linux
package tk_h264

// NVIDIA's driver libraries, by dlopen. NixOS keeps them in /run/opengl-driver/lib, which is in no default search path
// of a program built by Nix: that path is tried after the plain name.

import "core:sys/posix"

@(private = "file")
open_first :: proc(names: []cstring) -> posix.Symbol_Table {
	for name in names {
		if h := posix.dlopen(name, posix.RTLD_LOCAL + {.NOW}); h != nil { return h }
	}
	return nil
}

// libcuda and libnvidia-encode, with the calls nvenc_load takes; false (nothing kept open) when either is missing.
@(private)
nvenc_libraries_open :: proc(c: ^CUDA_Library, entry: ^NV_Entry) -> bool {
	cuda_library := open_first([]cstring{"libcuda.so.1", "/run/opengl-driver/lib/libcuda.so.1"})
	if cuda_library == nil { return false }
	encode_library := open_first([]cstring{"libnvidia-encode.so.1", "/run/opengl-driver/lib/libnvidia-encode.so.1"})
	if encode_library == nil { posix.dlclose(cuda_library); return false }
	c.init = auto_cast posix.dlsym(cuda_library, "cuInit")
	c.device_get_count = auto_cast posix.dlsym(cuda_library, "cuDeviceGetCount")
	c.device_get = auto_cast posix.dlsym(cuda_library, "cuDeviceGet")
	c.ctx_create = auto_cast posix.dlsym(cuda_library, "cuCtxCreate_v2")
	c.ctx_destroy = auto_cast posix.dlsym(cuda_library, "cuCtxDestroy_v2")
	c.ctx_push_current = auto_cast posix.dlsym(cuda_library, "cuCtxPushCurrent_v2")
	c.ctx_pop_current = auto_cast posix.dlsym(cuda_library, "cuCtxPopCurrent_v2")
	entry.get_max_supported_version = auto_cast posix.dlsym(encode_library, "NvEncodeAPIGetMaxSupportedVersion")
	entry.create_instance = auto_cast posix.dlsym(encode_library, "NvEncodeAPICreateInstance")
	if c.init == nil || c.device_get_count == nil || c.device_get == nil || c.ctx_create == nil || c.ctx_destroy == nil ||
	   c.ctx_push_current == nil || c.ctx_pop_current == nil || entry.get_max_supported_version == nil ||
	   entry.create_instance == nil {
		c^, entry^ = {}, {}
		posix.dlclose(encode_library)
		posix.dlclose(cuda_library)
		return false
	}
	return true
}
