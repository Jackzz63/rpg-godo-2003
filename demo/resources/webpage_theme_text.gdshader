shader_type canvas_item;
render_mode unshaded;

uniform sampler2D normal_strip : filter_nearest, repeat_disable;
uniform sampler2D strong_strip : filter_nearest, repeat_disable;
uniform sampler2D muted_strip : filter_nearest, repeat_disable;
uniform vec4 theme_shadow_color : source_color = vec4(0.08, 0.08, 0.10, 0.92);
uniform float gradient_origin_y = 0.0;
uniform float gradient_height = 16.0;
uniform bool use_line_map = false;
uniform sampler2D line_map : filter_nearest, repeat_disable;
uniform float line_map_height = 1.0;
uniform bool use_theme_colors = true;
uniform bool clip_shadow = false;
uniform vec2 shadow_clip_x = vec2(0.0);

const vec3 NORMAL_MARKER = vec3(1.0, 0.0, 1.0);
const vec3 STRONG_MARKER = vec3(0.0, 1.0, 0.0);
const vec3 MUTED_MARKER = vec3(0.0, 0.0, 1.0);
const vec3 SHADOW_MARKER = vec3(1.0, 0.0, 0.0);

varying vec2 local_position;
varying vec4 vertex_color;

void vertex() {
	local_position = VERTEX;
	vertex_color = COLOR;
}

bool is_marker(vec3 color, vec3 marker) {
	return distance(color, marker) < 0.01;
}

void fragment() {
	// COLOR already contains Godot's texture sample, including nine-patch/tile
	// UV processing. Re-sampling TEXTURE here distorts tiled button backgrounds.
	vec4 result = COLOR;
	float normalized_y = clamp(
		(local_position.y - gradient_origin_y) / max(gradient_height, 1.0),
		0.0, 0.999999);
	if (use_line_map) {
		normalized_y = texture(line_map, vec2(0.5, local_position.y / line_map_height)).r;
	}
	float webpage_row = clamp(floor(normalized_y * 16.0) - 1.0, 0.0, 15.0);
	float strip_y = (webpage_row + 0.5) / 16.0;

	if (use_theme_colors && is_marker(vertex_color.rgb, NORMAL_MARKER)) {
		result.rgb = texture(normal_strip, vec2(0.5, strip_y)).rgb;
	} else if (use_theme_colors && is_marker(vertex_color.rgb, STRONG_MARKER)) {
		result.rgb = texture(strong_strip, vec2(0.5, strip_y)).rgb;
	} else if (use_theme_colors && is_marker(vertex_color.rgb, MUTED_MARKER)) {
		result.rgb = texture(muted_strip, vec2(0.5, strip_y)).rgb;
	} else if (is_marker(vertex_color.rgb, SHADOW_MARKER)) {
		result.rgb = theme_shadow_color.rgb;
		result.a *= theme_shadow_color.a;
		if (clip_shadow && (local_position.x < shadow_clip_x.x || local_position.x >= shadow_clip_x.y)) {
			result.a = 0.0;
		}
	}

	COLOR = result;
}
