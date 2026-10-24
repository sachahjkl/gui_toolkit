# Application shaders

The renderer's effects are fixed (`rect.wgsl`, `filter.wgsl`, `slug.wgsl`...). An application can add its own: a **fragment function written in WGSL** that fills a rounded rectangle, with parameters, up to four textures and a blend mode. Everything around it is the renderer's own: the transform stack, the corner radii, the clips, the alpha stack, layers, planes (3D transforms), the order of drawing. Added in 0.25.0.

```odin
// once
shader := render.create_app_shader(&r, {name = "foil", wgsl = FOIL_WGSL, dxbc = FOIL_DXBC, hash = FOIL_HASH})
normals := render.create_texture_data(&r, 512, 512, .RGBA8)        // raw texels: no sRGB decoding, no premultiplication
render.update_texture_data(&r, normals, 0, 0, 512, 512, texels)

// every frame
draw.app_shader(&dc, shader, card, {{time, 0, 0, 0}, {light.x, light.y, 0.4, 1}}, {normals}, .Normal, radii = {16, 16, 16, 16})
```

## The shader

The module the backends compile is `rect.wgsl` + `app.wgsl` + your WGSL, concatenated (`render.app_module_source`). You define one function:

```wgsl
fn app_shade(a: AppIn) -> vec4<f32> {
	let p = app_param(0u);                                  // the draw's k-th vec4
	let n = textureSample(app_tex0, samp_img, a.uv).xyz * 2.0 - 1.0;
	return vec4<f32>(0.5 + 0.5 * n.x, 0.5 + 0.5 * n.y, 0.5, 1.0);
}
```

It returns the color of one pixel in **linear light with straight alpha**. The toolkit multiplies it by the coverage of the (rounded, clipped) rectangle, by the tint and alpha of the draw, converts it to the blend space of the target and blends it. `AppIn`:

| field | |
|---|---|
| `uv` | position in the rectangle, (0, 0) top-left to (1, 1) bottom-right (slightly outside on the antialiased rim) |
| `pos`, `size` | the same in local units (the units the rectangle was drawn in), and the rectangle's size |
| `px` | screen pixels per local unit (what the transforms made of a unit) |
| `frag` | the pixel in the render target |
| `space` | blend space of the target (0 linear, 1 sRGB); the color you return is linear either way |

Available to your code: `app_param(k)`, `app_tex0` .. `app_tex3` (`texture_2d<f32>`; an empty slot is a transparent 1 x 1 texel), the samplers of `rect.wgsl` (`samp_img`: trilinear, clamp; `samp_wrap`: trilinear, repeat; `samp`), and everything `rect.wgsl` declares. `app_shade` runs in uniform control flow, so `textureSample`, `dpdx` and `dpdy` work anywhere in it. Parameters are vec4 values, at most `render.MAX_APP_PARAMS` (64) per draw; a draw with fewer reads zeros for the rest only by accident, so declare what you read.

## Direct3D 11: the precompiled pixel shader

WebGPU compiles the WGSL as it is. Direct3D 11 embeds DXBC, as the toolkit's own shaders do: naga writes HLSL from the module, `D3DCompile` compiles its `ps_app` entry. Run, after editing the WGSL (and after a toolkit update that changes `rect.wgsl`):

```
odin run <toolkit>/tools/shaders -- app foil path\foil.wgsl path\shaders          # writes foil.dxbc and foil.sha256
odin run <toolkit>/tools/shaders -- app foil path\foil.wgsl path\shaders -check   # exit code 1 when stale
```

and load the two files with `#load`. `create_app_shader` compares the SHA-256 of the module (`render.app_module_hash`) with the one in `foil.sha256`: a blob built from other sources is refused with a message, never drawn. The translator is `tools/wgsl2hlsl` (naga, pinned; `tools\build_naga.ps1` builds it, needs `cargo`); a program that only embeds blobs does not need it. The vertex shader of the D3D11 pipeline is the renderer's.

## Data textures

`render.create_texture_data(r, w, h, format = .RGBA8, mips = true)` makes a texture of raw 8-bit values: `.RGBA8` (a normal map, a mask pack) or `.R8` (a height map). Unlike `create_texture_rgba` nothing converts them: no sRGB decoding, no premultiplication, whatever the blend space, so `texel * 2 - 1` is a vector. `update_texture_data(r, t, x, y, w, h, pixels, stride = 0)` uploads a block. With `mips` the full chain is built (box filter) before the next frame after an update, so a texture seen smaller than itself is filtered, not aliased. Destroy with `destroy_texture`. After a device loss the contents are gone (same handle): upload again when `render.Renderer.device_generation` changes, as for images.

## draw.app_shader

```odin
app_shader :: proc(c: ^Context, shader: render.App_Shader, r: Rect, params: []Vec4, textures: []render.Texture = nil,
                   blend := render.App_Blend.Normal, radii: [4]f32 = {}, tint: Color = WHITE) -> bool
```

Fills `r` (current local space), in order with everything else: under the current transform (a rotated rectangle keeps exact rounded corners and a 1 px antialiased edge), clips, alpha stack, inside layers and planes. Blend modes (`App_Blend`, fixed-function blending of the premultiplied result): `Normal` (over), `Add` (`dst + src`: a glow adds its light), `Screen`, `Multiply`.

It returns **false and draws nothing** when the shader is 0 (it failed to build: the caller draws its fallback), when a picture is being recorded (`picture_begin`: an application shader is not recordable, its parameters change every frame; draw it around the replay), or when there are more than 64 parameters or 4 textures.

**Kept layers.** A plane or layer given a `cache_key` keeps its pixels, shader output included: an animated shader must make its time part of the key (or the layer is not kept), a still one costs nothing while the key holds. The pointer-tilt of a card that is only projected differently (`draw_plane`'s matrix changes, the plane's content does not) leaves the kept layer alone.

## Cost

One instance and one draw call per `app_shader`, with its bind group on WebGPU (an application shader is a batch of its own: it breaks batching with its neighbors, like an image of another texture). The pixel cost is yours: the rectangle's coverage, the clips and the tint add a few operations to `app_shade`.

## Tests

`tests/appshaders` (both backends; `tools\test_backends.ps1 -Backend wgpu -Only appshaders`): colors in either blend space, uv, raw data textures, two textures and empty slots, the four blend modes against their formulas in both spaces, alpha stack and tint, rounded corners and clips, a rotated and scaled rectangle (`size` and `px`), inside a layer and a plane, 8 draws with their own parameters, the refusals (shader 0, too many parameters or textures, recording, a stale blob, no blob), a device loss, and mip filtering of a data texture.
