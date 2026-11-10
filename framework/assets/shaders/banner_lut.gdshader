shader_type canvas_item;

// LUT colorization for team banner layers (TDD §3.19): samples the built-in
// grayscale TEXTURE, quantizes its luminance to 16 levels and remaps through
// a 16x1 palette texture built at runtime from the catalog's Color array.
// Transparent sprite pixels stay transparent.
//
// H3 (2026-11-09): the sheet-split art is luminance-flat — icons sit in
// ≈0.43–0.81 everywhere, bases are a bright field ≈0.75–0.81 + a dark frame
// <0.25 — so raw 0–1 quantization collapsed EVERY palette onto indices ~11–12
// (one flat bright hue near the right end of the ramp). remap_lo/remap_hi
// stretch the art's actual luminance window onto the full 0–15 index span:
// pixels at/below remap_lo clamp to the darkest entry, at/above remap_hi to
// the brightest. Real art with a wider luminance range simply uses more of
// its own spread (the window is a floor, not a squeeze).
uniform sampler2D lut_tex : source_color;
uniform float remap_lo : hint_range(0.0, 1.0) = 0.35;
uniform float remap_hi : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	// No early return (invalid in Godot fragment shaders): transparent pixels
	// pass through with their ~0 alpha, which is the same result.
	vec4 tex = texture(TEXTURE, UV);
	float lum = dot(tex.rgb, vec3(0.2126, 0.7152, 0.0722));
	float t = clamp((lum - remap_lo) / max(remap_hi - remap_lo, 0.001), 0.0, 1.0);
	float idx = clamp(floor(t * 16.0), 0.0, 15.0);
	vec4 palette = texture(lut_tex, vec2((idx + 0.5) / 16.0, 0.5));
	COLOR = vec4(palette.rgb, tex.a);
}
