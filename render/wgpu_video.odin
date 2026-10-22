package render

// The WebGPU backend has no zero-copy path for decoder textures (wgpu-native cannot import a Direct3D 11 texture); pictures
// come in memory and go through the same shader (video.wgsl). Not written yet: the backend reports that it cannot.

wgpu_create_video_target :: proc(r: ^Renderer, w, h: int) -> Texture {
	return wgpu_create_texture_rgba(r, w, h, true)
}

wgpu_video_convert :: proc(r: ^Renderer, dst: Texture, p: Video_Picture) -> bool {
	return false
}
