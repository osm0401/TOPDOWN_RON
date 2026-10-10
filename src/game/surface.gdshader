shader_type spatial;
// PLACEHOLDER procedural PBR surfaces (no texture files): plaster/concrete/asphalt (mode 0),
// floor tiles with joints (mode 1), wood planks (mode 2). The pattern is projected in world
// space (meters) along the dominant normal axis, so any box or plane tiles without stretching.
// Swap for real scanned texture sets later; the parameters come from data/view3d.json.

uniform int mode = 0;
uniform vec3 color_a : source_color = vec3(0.5);
uniform vec3 color_b : source_color = vec3(0.4);
uniform vec3 grout : source_color = vec3(0.1);
uniform vec3 tint : source_color = vec3(1.0);
uniform float scale = 1.0;      // noise features per meter
uniform float tile_m = 0.6;     // tile / plank width in meters
uniform float rough_min = 0.6;
uniform float rough_max = 0.95;
uniform float bump = 0.05;
uniform float grime_m = 0.0;    // height of the dirty band at the foot of vertical surfaces

varying vec3 wpos;
varying vec3 wnrm;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + 17.0;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 an = abs(wnrm);
	vec2 uv;
	if (an.y >= an.x && an.y >= an.z) {
		uv = wpos.xz;
	} else if (an.x >= an.z) {
		uv = wpos.zy;
	} else {
		uv = wpos.xy;
	}
	float aa = max(length(dFdx(uv)), length(dFdy(uv)));  // pixel footprint in meters: keeps thin joints from shimmering
	float n = fbm(uv * scale);
	float fine = vnoise(uv * scale * 9.0);
	vec3 col;
	float h;
	float rough;
	if (mode == 1) {
		vec2 g = uv / tile_m;
		vec2 id = floor(g);
		vec2 f = fract(g);
		float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) * tile_m;
		float joint = 1.0 - smoothstep(0.008 - aa, 0.008 + aa, edge);
		vec3 tile = mix(color_a, color_b, clamp(hash(id) * 0.8 + n * 0.4, 0.0, 1.0));
		col = mix(tile, grout, joint);
		h = (1.0 - joint) * 0.6 + n * 0.2 + fine * 0.05;
		rough = mix(rough_min, rough_max, clamp(n + joint, 0.0, 1.0));
	} else if (mode == 2) {
		float px = uv.x / tile_m;
		float plank = floor(px);
		float grain = fbm(vec2(uv.x * 14.0 + hash(vec2(plank, 1.0)) * 40.0, uv.y * 1.2));
		float seam = 1.0 - smoothstep(0.004 - aa, 0.004 + aa, min(fract(px), 1.0 - fract(px)) * tile_m);
		col = mix(mix(color_a, color_b, grain), grout, seam);
		h = grain * 0.3 - seam * 0.5;
		rough = mix(rough_min, rough_max, grain);
	} else {
		col = mix(color_a, color_b, n) * (0.85 + 0.3 * fine);
		h = n * 0.7 + fine * 0.3;
		rough = mix(rough_min, rough_max, fine);
	}
	if (grime_m > 0.0 && an.y < 0.5) {
		float g = smoothstep(grime_m, 0.0, wpos.y) * (0.5 + 0.5 * n);
		col *= 1.0 - 0.55 * g;
		rough = mix(rough, rough_max, g);
	}
	ALBEDO = col * tint;
	ROUGHNESS = rough;
	SPECULAR = 0.3;
	// bump from the height field (surface-gradient method, view space)
	vec3 dpdx = dFdx(VERTEX);
	vec3 dpdy = dFdy(VERTEX);
	vec3 r1 = cross(dpdy, NORMAL);
	vec3 r2 = cross(NORMAL, dpdx);
	float det = dot(dpdx, r1);
	vec3 grad = sign(det) * (dFdx(h) * r1 + dFdy(h) * r2);
	NORMAL = normalize(abs(det) * NORMAL - bump * grad);
}
