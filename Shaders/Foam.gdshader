shader_type spatial;
render_mode vertex_lighting;


global uniform vec2 wind_direction;

uniform float threshold;
uniform float smoothness;
uniform float alpha_threshold : hint_range(0.0, 1.0, 0.01);
uniform float speed;
uniform float tiling;
uniform vec4 color : source_color;
uniform sampler2D color_tex;
uniform sampler2D noise_tex;
uniform sampler2D flow_tex;

varying vec3 world_position;
varying vec3 normal;


void vertex()
{
    world_position = NODE_POSITION_WORLD.xyz + VERTEX.xyz;
	normal = NORMAL;
}

void fragment() {
	vec3 forward = cross(normalize(vec3(UV.x, 0, 0)), normal);
	float movement = fract(TIME * speed + UV.y);
	vec2 world_position_plane = vec2(world_position.x * 0.05, world_position.z * 0.05);// + fract(TIME * speed + UV.y);
	vec2 flow = texture(flow_tex, world_position_plane).rg * 2.0 - 1.0;
	//float noise = (texture(noise_tex, vec2((UV.x * 0.01 + TIME * 0.05 + world_position_plane.x + world_position_plane.y) - flow.x, UV.y - flow.y)).r - 0.5) * 2.0;
	float noise = texture(noise_tex, vec2(world_position_plane.x * tiling - flow.x + movement, world_position_plane.y * tiling - flow.y + movement)).r * 2.0 - 1.0;
	float value = smoothstep(threshold - smoothness, threshold + smoothness, UV.y + noise * 0.5);
	if (color.a * value < alpha_threshold)
		discard;
	vec3 col = texture(color_tex, vec2(color.a * value, 0.5)).rgb;
	ALBEDO = col;
	//ALBEDO = vec3(fract(TIME * speed + UV.y));
	//ALPHA = color.a * value;
}