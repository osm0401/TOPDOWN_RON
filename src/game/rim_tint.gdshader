shader_type spatial;
// Overlay for the officer models: their player colour as a glow along the silhouette (strongest
// where the surface turns away from the camera) plus a faint even tint. The two officers stay
// readable and told apart in a dark room while the model's own clothes and gear show through.
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform vec4 tint : source_color = vec4(0.3, 0.55, 1.0, 1.0);
uniform float rim = 0.9;   // opacity at the silhouette
uniform float even = 0.04; // opacity everywhere

void fragment() {
	float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = tint.rgb;
	ALPHA = clamp(even + rim * edge, 0.0, 1.0) * tint.a;
}
