shader_type spatial;
// PLACEHOLDER procedural PBR surfaces (no texture files): plaster/concrete/asphalt/grass/fabric
// (mode 0), floor tiles with joints (mode 1), wood planks (mode 2, end joints every plank_len m
// when > 0), checkerboard tiles (mode 3), bricks in running bond (mode 4: tile_m long, half as
// tall). The pattern is projected in world space (meters) along the dominant normal axis, so any
// box or plane tiles without stretching; object_space projects in the mesh's own space instead
// (furniture and door leaves that move keep their grain). The parameters come from
// data/view3d.json "surfaces" (furniture: PropModels).

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
uniform float plank_len = 0.0;  // wood: plank length in meters (0: endless planks)
uniform bool object_space = false;
uniform float dirt = 0.0;       // 0..1: large faint stains and worn patches (darker, rougher)
uniform float speckle = 0.0;    // 0..1: fine light / dark grains (asphalt, concrete, terrazzo)
uniform float bevel = 0.0;      // tiles: width (m) of the rounded edge each tile gets at its joints
// a texture (assets/textures/<set>/<key>.png) replaces the pattern's colours; its brightness
// gives the bumps. tex_m: meters the picture covers.
uniform bool use_tex = false;
uniform sampler2D tex_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tex_m = 2.0;
// rain (outside): wet 0..1 darkens and glosses the surface; puddles 0..1 is how much of the ground
// holds standing water, mirror-smooth, with rings where the drops land.
uniform float wet = 0.0;
uniform float puddles = 0.0;

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

// Rings spreading where drops land in standing water: height -1..1 at uv (meters), drops in cells
// of 0.35 m, each landing at its own moment.
float ripples(vec2 p, float t) {
	float sum = 0.0;
	vec2 cell = floor(p / 0.35);
	for (int dx = -1; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			vec2 id = cell + vec2(float(dx), float(dy));
			float ph = fract(t * 0.9 + hash(id));
			vec2 c = (id + vec2(hash(id + 1.7), hash(id + 5.3))) * 0.35;
			float w = length(p - c) - ph * 0.22;
			sum += sin(w * 150.0) * exp(-w * w * 1800.0) * (1.0 - ph);
		}
	}
	return sum;
}

void vertex() {
	if (object_space) {
		wpos = VERTEX;
		wnrm = NORMAL;
	} else {
		wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	}
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
		float round_edge = bevel > 0.0 ? smoothstep(0.0, bevel, edge) : 1.0;  // tiles dome toward their middle
		h = (1.0 - joint) * 0.6 * round_edge + n * 0.2 + fine * 0.05;
		rough = mix(rough_min, rough_max, clamp(n + joint + hash(id + 3.0) * 0.25 - 0.1, 0.0, 1.0));
	} else if (mode == 2) {
		float px = uv.x / tile_m;
		float plank = floor(px);
		float along = uv.y;
		float piece = 0.0;
		float seam_end = 0.0;
		if (plank_len > 0.0) {
			float py = (uv.y + hash(vec2(plank, 7.0)) * plank_len) / plank_len;
			piece = floor(py);
			seam_end = 1.0 - smoothstep(0.003 - aa, 0.003 + aa, min(fract(py), 1.0 - fract(py)) * plank_len);
		}
		float grain = fbm(vec2(uv.x * 14.0 + hash(vec2(plank, 1.0 + piece)) * 40.0, along * 1.2));
		float seam = max(1.0 - smoothstep(0.004 - aa, 0.004 + aa, min(fract(px), 1.0 - fract(px)) * tile_m), seam_end);
		float tone = hash(vec2(plank, 3.0 + piece)) * 0.35;  // every board a little lighter or darker
		col = mix(mix(color_a, color_b, clamp(grain + tone - 0.15, 0.0, 1.0)), grout, seam);
		h = grain * 0.3 - seam * 0.5;
		rough = mix(rough_min, rough_max, grain);
	} else if (mode == 3) {
		vec2 g = uv / tile_m;
		vec2 id = floor(g);
		vec2 f = fract(g);
		float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) * tile_m;
		float joint = 1.0 - smoothstep(0.003 - aa, 0.003 + aa, edge);
		float check = mod(id.x + id.y, 2.0);
		vec3 tile = mix(color_a, color_b, check) * (0.92 + 0.16 * n);
		col = mix(tile, grout, joint);
		h = (1.0 - joint) * 0.6 + fine * 0.05;
		rough = mix(rough_min, rough_max, clamp(n * 0.6 + joint, 0.0, 1.0));
	} else if (mode == 4) {
		float bh = tile_m * 0.5;  // brick course height
		float row = floor(uv.y / bh);
		float bx = uv.x / tile_m + (mod(row, 2.0) * 0.5);
		vec2 f = vec2(fract(bx), fract(uv.y / bh));
		float edge = min(min(f.x, 1.0 - f.x) * tile_m, min(f.y, 1.0 - f.y) * bh);
		float joint = 1.0 - smoothstep(0.006 - aa, 0.006 + aa, edge);
		vec3 brick = mix(color_a, color_b, clamp(hash(vec2(floor(bx), row)) * 0.9 + n * 0.3, 0.0, 1.0));
		col = mix(brick * (0.85 + 0.3 * fine), grout, joint);
		h = (1.0 - joint) * 0.7 + fine * 0.15;
		rough = mix(rough_min, rough_max, clamp(fine + joint, 0.0, 1.0));
	} else {
		col = mix(color_a, color_b, n) * (0.85 + 0.3 * fine);
		h = n * 0.7 + fine * 0.3;
		rough = mix(rough_min, rough_max, fine);
	}
	if (use_tex) {  // a picture of the real surface instead of the pattern's colours
		vec3 t = texture(tex_albedo, uv / tex_m).rgb;
		col = t * (0.92 + 0.16 * n);
		h = dot(t, vec3(0.3, 0.5, 0.2)) * 1.4 + fine * 0.05;
	}
	if (speckle > 0.0) {
		float g1 = vnoise(uv * 90.0);
		float g2 = vnoise(uv * 160.0 + 31.0);
		col *= 1.0 + speckle * (smoothstep(0.82, 0.95, g1) * 0.5 - smoothstep(0.8, 0.95, g2) * 0.45);
	}
	if (dirt > 0.0) {
		float patch = fbm(uv * 0.32 + vec2(13.0, 7.0));
		float worn = smoothstep(0.48, 0.78, patch) * dirt;
		col *= 1.0 - 0.35 * worn;
		rough = mix(rough, rough_max, worn);
		float tide = smoothstep(0.012, 0.0, abs(patch - 0.62)) * dirt;  // the dried edge of an old spill
		col *= 1.0 - 0.18 * tide;
	}
	if (grime_m > 0.0 && an.y < 0.5) {
		float g = smoothstep(grime_m, 0.0, wpos.y) * (0.5 + 0.5 * n);
		col *= 1.0 - 0.55 * g;
		rough = mix(rough, rough_max, g);
	}
	if (wet > 0.0) {
		float pud = 0.0;
		if (an.y > 0.5) {
			pud = smoothstep(0.56, 0.6, fbm(uv * 0.45 + vec2(3.7, 9.1))) * puddles;
		}
		col *= 1.0 - 0.32 * wet;  // wet stone, asphalt and grass look darker
		col = mix(col, col * 0.6, pud);
		rough = mix(rough, 0.3, wet * 0.75);
		rough = mix(rough, 0.03, pud);
		float rings = ripples(uv, TIME) * (1.0 - smoothstep(0.006, 0.02, aa));  // fades out when too small to see
		h = mix(h, rings * 0.0025 / max(bump, 0.001), pud);  // flat water, but for the rings
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
