shader_type spatial;
// Character models (CharacterModels puts it on every surface at load): the model's own texture,
// with per-person changes set per instance, so one model file gives many different people:
// - top_tint / bottom_tint: the upper garment and the trousers recoloured (rgb: new colour, a: how
//   much). Which texels are "the top" is told by their colour (close to top_key, the garment's
//   colour as made, found at load) and their height on the body, so pockets, folds and seams keep
//   their shading.
// - skin_tint: multiplies skin-like texels (face, neck, hands).
// - hair: short hair painted on the scalp (rgb colour, a coverage): a hairline across the forehead
//   that drops to the nape at the back, fine strands in it. `head` is the head's top, face front and
//   back (height shares) found at load.
// - wound0..3: blood soaked into the clothes round a hit (xyz: rest position / body height,
//   w: radius in the same units, 0 = none); wet blood is darker and glossy.
// CUSTOM0 holds each vertex's rest position / body height (the pose does not move the masks).

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_tex = true;
uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness = 0.85;
uniform float metallic = 0.0;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform vec3 top_key : source_color = vec3(0.5);
uniform vec3 bottom_key : source_color = vec3(0.2);
uniform float key_tol = 0.2;
uniform float top_low = 0.47;  // the top's lower edge on the body (height share); the sleeves reach lower
uniform float mid_x = 0.0;
uniform vec3 head = vec3(1.0, 0.06, -0.06);  // top y, face front z, back of the head z (height shares)

instance uniform vec4 top_tint = vec4(0.0);
instance uniform vec4 bottom_tint = vec4(0.0);
instance uniform vec4 skin_tint = vec4(1.0, 1.0, 1.0, 0.0);
instance uniform vec4 wound0 = vec4(0.0);
instance uniform vec4 wound1 = vec4(0.0);
instance uniform vec4 wound2 = vec4(0.0);
instance uniform vec4 wound3 = vec4(0.0);
instance uniform float dirt = 0.0;
instance uniform vec4 hair = vec4(0.0);

varying vec3 rest;

void vertex() {
	rest = CUSTOM0.xyz;
}

float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x), mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x), mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// How soaked this point is by one wound: a ragged patch, with a little run of blood below it.
float wound(vec4 w, float n) {
	if (w.w <= 0.0) {
		return 0.0;
	}
	vec3 d = rest - w.xyz;
	float r = w.w * (0.7 + 0.6 * n);
	float patch = 1.0 - smoothstep(r * 0.55, r, length(d));
	float run = (1.0 - smoothstep(w.w * 0.12, w.w * 0.3, abs(d.x + (n - 0.5) * w.w * 0.3))) // a narrow trickle
			* step(d.y, 0.0) * (1.0 - smoothstep(w.w * 1.2, w.w * 3.0, -d.y)) * step(abs(d.z), w.w * 0.8);
	return max(patch, run * 0.8);
}

// How much a texel belongs to the garment made in colour `key`: the same hue whether lit or in
// shadow (its colour direction, brightness left out), within a broad range of brightness. A grey,
// white or black garment (an unsaturated key) takes only texels about as unsaturated.
float cloth(vec3 g, float lum, vec3 key, float key_l) {
	vec3 gk = sqrt(key);
	float sat_k = max(max(gk.r, gk.g), gk.b) - min(min(gk.r, gk.g), gk.b);
	float sat = max(max(g.r, g.g), g.b) - min(min(g.r, g.g), g.b);
	vec3 dir_k = gk / max(gk.r + gk.g + gk.b, 0.001);
	vec3 dir = g / max(g.r + g.g + g.b, 0.001);
	float hue_ok = 1.0 - smoothstep(key_tol * 0.55, key_tol * 0.9, distance(dir, dir_k));
	float grey = 1.0 - smoothstep(0.08, 0.16, sat_k);  // the key is about colourless
	hue_ok = mix(hue_ok, 1.0 - smoothstep(0.1, 0.18, sat), grey);
	float ratio = lum / key_l;
	float bright_ok = smoothstep(0.05, 0.12, ratio) * (1.0 - smoothstep(grey > 0.5 ? 2.2 : 3.2, grey > 0.5 ? 3.0 : 4.2, ratio));  // deep folds too
	return hue_ok * bright_ok;
}

void fragment() {
	vec4 t = has_tex ? texture(albedo_tex, UV) : vec4(1.0);
	vec3 c = t.rgb * albedo.rgb;
	vec3 g = sqrt(max(c, vec3(0.0)));  // closer to how far apart colours look
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	float y = rest.y;
	float top_l = max(dot(top_key, vec3(0.299, 0.587, 0.114)), 0.02);
	float bottom_l = max(dot(bottom_key, vec3(0.299, 0.587, 0.114)), 0.02);
	// skin: warm, not too dark or saturated (hair and red cloth stay out); never taken for cloth
	float warm = g.r - g.b;
	float skinlike = step(g.b, g.g) * step(g.g, g.r) * smoothstep(0.06, 0.1, warm) * (1.0 - smoothstep(0.42, 0.5, warm))
			* smoothstep(0.3, 0.4, g.r) * smoothstep(0.68, 0.74, g.g / max(g.r, 0.001));  // red cloth has far less green than skin
	float face = smoothstep(0.86, 0.88, y) * (1.0 - smoothstep(0.03, 0.05, abs(rest.x - mid_x)))
			* smoothstep(head.y - 0.06, head.y - 0.03, rest.z);  // mouth, nose: never a hood
	float on_body = 1.0 - smoothstep(0.09, 0.12, abs(rest.x - mid_x));  // the torso, not the arms hanging beside it
	float low_edge = mix(0.43, top_low - 0.01, on_body);
	float top = cloth(g, lum, top_key, top_l) * smoothstep(low_edge - 0.015, low_edge + 0.015, y)
			* (1.0 - smoothstep(0.9, 0.94, y)) * (1.0 - skinlike) * (1.0 - face);  // up to a hood's rim
	float bottom = cloth(g, lum, bottom_key, bottom_l) * smoothstep(0.06, 0.09, y) * (1.0 - smoothstep(0.58, 0.64, y))
			* (1.0 - top) * (1.0 - skinlike);
	c = mix(c, clamp(top_tint.rgb * (lum / top_l), 0.0, 1.0), top * top_tint.a);
	c = mix(c, clamp(bottom_tint.rgb * (lum / bottom_l), 0.0, 1.0), bottom * bottom_tint.a);
	c = mix(c, c * skin_tint.rgb, skinlike * skin_tint.a);
	float n = noise3(rest * 70.0) * 0.6 + noise3(rest * 23.0) * 0.4;
	if (hair.a > 0.0) {
		float depth = max(head.y - head.z, 0.02);
		float t = clamp((rest.z - head.z) / depth, 0.0, 1.0);  // 0 the back of the head .. 1 the face
		float line = mix(head.x - 0.125, head.x - 0.05, smoothstep(0.1, 0.36, t));  // down to the nape at the back, above the ears and the brow
		float m = smoothstep(line - 0.004, line + 0.004, y + (n - 0.5) * 0.008) * hair.a;
		float strands = 0.75 + 0.45 * noise3(vec3(rest.x * 900.0, rest.y * 140.0, rest.z * 900.0));
		c = mix(c, hair.rgb * strands, m);
	}
	c *= 1.0 - dirt * 0.35 * smoothstep(0.35, 0.0, y) * (0.6 + 0.4 * n);  // dust up the legs
	float b = max(max(wound(wound0, n), wound(wound1, n)), max(wound(wound2, n), wound(wound3, n)));
	vec3 blood = vec3(0.28, 0.012, 0.016) * (0.65 + 0.5 * n);
	c = mix(c, blood, b * 0.92);
	ALBEDO = c;
	ROUGHNESS = mix(roughness, 0.22, b * 0.85);
	METALLIC = metallic;
	SPECULAR = mix(0.4, 0.6, b);
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
}
