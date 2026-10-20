shader_type canvas_item;
// Hurt look over the whole screen: red edges that flash on a hit, and while badly hurt a pulsing
// red rim and washed-out colours. ScreenFx shows this rect only while one of them is above zero.

uniform float hit = 0.0;   // 0..1, a fresh hit
uniform float hurt = 0.0;  // 0..1, how badly hurt (pulses with the heartbeat)
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = (uv - vec2(0.5)) * vec2(1.25, 1.0);
	float edge = smoothstep(0.22, 0.72, length(d));
	vec3 c = texture(screen_tex, uv).rgb;
	float grey = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(grey), hurt * 0.55);
	float a = clamp(edge * (hit * 0.85 + hurt * 0.65) + hit * 0.1, 0.0, 0.92);
	c = mix(c, vec3(0.42, 0.0, 0.0), a);
	COLOR = vec4(c, 1.0);
}
