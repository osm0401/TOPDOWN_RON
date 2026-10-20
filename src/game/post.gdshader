shader_type canvas_item;
// Lens and film over the 3D picture (under the HUD): darker corners, a faint colour fringe toward
// the edges (cheap lens) and moving film grain, stronger in the darks than in the lights. The grain
// multiplies, so black stays black. Values: data/view3d.json graphics (vignette, grade.grain,
// grade.aberration).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float vignette = 0.35;
uniform float grain = 0.0;
uniform float aberration = 0.0;

float hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 off = (uv - 0.5) * aberration;
	vec3 c = vec3(texture(screen_tex, uv + off).r, texture(screen_tex, uv).g, texture(screen_tex, uv - off).b);
	float d = length((uv - 0.5) * vec2(1.6, 1.2));
	c *= 1.0 - smoothstep(0.55, 1.15, d) * vignette;
	if (grain > 0.0) {
		float n = hash(floor(FRAGCOORD.xy) + floor(fract(TIME * 0.37) * 997.0)) - 0.5;
		float lum = dot(c, vec3(0.299, 0.587, 0.114));
		c *= 1.0 + n * grain * 2.0 * (1.0 - 0.6 * clamp(lum, 0.0, 1.0));
	}
	COLOR = vec4(c, 1.0);
}
