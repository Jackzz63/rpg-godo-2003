shader_type canvas_item;
render_mode unshaded;

uniform sampler2D normal_strip : filter_nearest, repeat_disable;
uniform sampler2D strong_strip : filter_nearest, repeat_disable;
uniform sampler2D muted_strip : filter_nearest, repeat_disable;
uniform vec4 theme_shadow_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec2 shadow_uv_offset = vec2(0.0625);
uniform bool draw_shadow = true;
uniform int fixed_role = 0;
uniform float gradient_origin_y = 0.0;
uniform float gradient_height = 16.0;

const vec3 NORMAL_MARKER = vec3(1.0, 0.0, 1.0);
const vec3 STRONG_MARKER = vec3(0.0, 1.0, 0.0);
const vec3 MUTED_MARKER = vec3(0.0, 0.0, 1.0);

varying vec2 local_position;
varying vec4 vertex_color;

void vertex() {
	local_position = VERTEX;
	vertex_color = COLOR;
}

vec3 sample_strip(sampler2D strip, float normalized_y) {
	float row_position = clamp(normalized_y, 0.0, 1.0) * 15.0;
	float first_row = floor(row_position);
	float second_row = min(first_row + 1.0, 15.0);
	float blend = fract(row_position);
	vec3 first_color = texture(strip, vec2(0.5, (first_row + 0.5) / 16.0)).rgb;
	vec3 second_color = texture(strip, vec2(0.5, (second_row + 0.5) / 16.0)).rgb;
	return mix(first_color, second_color, blend);
}

vec3 sample_role_color(int role, float normalized_y) {
	if (role == 1) {
		return sample_strip(strong_strip, normalized_y);
	}
	if (role == 3) {
		return sample_strip(muted_strip, normalized_y);
	}
	return sample_strip(normal_strip, normalized_y);
}

void fragment() {
	vec4 source = texture(TEXTURE, UV);
	int role = fixed_role;
	if (role < 0) {
		if (distance(vertex_color.rgb, STRONG_MARKER) < 0.01) {
			role = 1;
		} else if (distance(vertex_color.rgb, MUTED_MARKER) < 0.01) {
			role = 3;
		} else {
			role = 0;
		}
	}

	float normalized_y = clamp(
		(local_position.y - gradient_origin_y) / max(gradient_height, 1.0),
		0.0, 1.0);
	vec3 themed_color = sample_role_color(role, normalized_y);
	float foreground_alpha = source.a * vertex_color.a;
	float shadow_alpha = 0.0;
	if (draw_shadow) {
		vec2 shadow_uv = UV - shadow_uv_offset;
		float in_bounds = step(0.0, shadow_uv.x) * step(0.0, shadow_uv.y)
			* step(shadow_uv.x, 1.0) * step(shadow_uv.y, 1.0);
		shadow_alpha = texture(TEXTURE, clamp(shadow_uv, vec2(0.0), vec2(1.0))).a
			* in_bounds * theme_shadow_color.a * vertex_color.a;
	}
	float shadow_only_alpha = shadow_alpha * (1.0 - foreground_alpha);
	float output_alpha = foreground_alpha + shadow_only_alpha;
	vec3 output_color = (
		themed_color * foreground_alpha
		+ theme_shadow_color.rgb * shadow_only_alpha
	) / max(output_alpha, 0.00001);
	COLOR = vec4(output_color, output_alpha);
}
