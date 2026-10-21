shader_type canvas_item;
render_mode unshaded;

const float TRANSITION_WIDTH = 0.5;

varying vec4 vertex_color;

void vertex() {
	vertex_color = COLOR;
}

void fragment() {
	vec2 texture_size = vec2(1.0) / TEXTURE_PIXEL_SIZE;
	vec2 box_size = clamp(
		fwidth(UV) * texture_size * TRANSITION_WIDTH,
		vec2(0.00001),
		vec2(1.0));
	vec2 texel = UV * texture_size - 0.5 * box_size;
	vec2 texel_offset = smoothstep(
		vec2(1.0) - box_size,
		vec2(1.0),
		fract(texel));
	vec2 sample_uv = (
		floor(texel) + vec2(0.5) + texel_offset
		) * TEXTURE_PIXEL_SIZE;
	COLOR = texture(TEXTURE, sample_uv) * vertex_color;
}
