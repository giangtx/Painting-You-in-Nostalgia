shader_type spatial;
//render_mode depth_draw_never;

global uniform vec2 wind_direction;
global uniform sampler2D clouds_tex;
global uniform float clouds_speed;
global uniform sampler2D ripples_tex;
global uniform float ripples_mult;

uniform vec3 base_color : source_color;
uniform sampler2D color_ramp_tex;
uniform vec3 map_center_and_size; // .xy = world x and z, .z = size
uniform sampler2D noise_tex;
uniform float water_speed;
uniform float roughness;
//uniform float small_normal_map_weigth : hint_range(0.0, 1.0);
uniform sampler2D normal_map : hint_normal;
uniform sampler2D normal_distortion;
uniform sampler2D height_map;
uniform float alpha : hint_range(0.0, 1.0);
uniform float ripples_speed;
uniform float ripples_radius;
uniform float ripples_width;
uniform float reflection_strength;

varying vec3 world_position;
varying vec3 screen_position;

//uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;


void vertex()
{
    //world_position = NODE_POSITION_WORLD.xyz + VERTEX.xyz;
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 vert = vec4(VERTEX, 1.0);
	vert = MODELVIEW_MATRIX * vert;
	vert = PROJECTION_MATRIX * vert;
	screen_position = vert.xyz;
}

void fragment() {
	float value = clamp(distance(world_position.xz, map_center_and_size.xy) / (map_center_and_size.z + 15.0), 0.1, 0.9);
	vec4 color = texture(color_ramp_tex, vec2(value, 0.0));
	float distortion = texture(normal_distortion, world_position.xz * 0.05).r;
	float noise = texture(noise_tex, fract(world_position.xz * 0.05)).r * (1.0-pow(value, 2));
	//vec2 grid_uv = (world_position.xz - top_down_camera_position.xz) / (top_down_camera_size * 1.0);
	//grid_uv *= 0.7; // Scale
	//grid_uv += 0.2; // Scale displacement
	//grid_uv += 0.5;
	//grid_uv += distortion * sin(world_position.xz * 4.0 + TIME * 2.0) * 0.05;
	//float isle = textureLod(grid_tex, clamp(grid_uv, 0, 1), 4).b;
	//vec2 dir = smoothstep(0.01, 0.01, vec2(dFdx(isle), dFdy(isle)));
	vec2 wind = wind_direction; //- isle;
	vec2 uv = world_position.xz * 0.05 + TIME * water_speed * -wind;
	// CLOUDS
    float reflection_height = 1.0;
    vec3 viewDir = normalize(normalize(-VERTEX)*mat3(TANGENT,-BINORMAL,NORMAL));
    vec2 p = viewDir.xy / viewDir.z * reflection_height;
	vec2 clouds_uv = world_position.xz * 0.001 + TIME * clouds_speed * -wind;
	clouds_uv.x += (sin(TIME * 5.0 + world_position.x * 1.0 + world_position.z * 1.0) + 1.0) * 0.025;
    clouds_uv = clouds_uv - p;
	vec3 clouds = texture(clouds_tex, clouds_uv + distortion * 3.0).rgb * reflection_strength;
	//float clouds_mask = texture(clouds_tex, clouds_uv * 0.1).r;
	//clouds = clouds * clouds_mask;
	// WAVES
	//float waves = (sin(TIME * 1.0 + world_position.x * -wind_direction.x + world_position.z * -wind_direction.y) + 1.0) * 0.5;
    //p = viewDir.xy / viewDir.z * -waves;
	//vec2 waves_uv = vec2(waves) - p;
	vec2 normal_uv = (uv + distortion) * (abs(wind) + 0.5) * 0.25;
	vec3 normal = texture(normal_map, normal_uv).rgb;
	//normal_uv = ((world_position.xz * 0.05 + TIME * water_speed * -wind_direction) + distortion) * (wind_direction + 0.5) * 0.25;
	vec3 height = texture(height_map, normal_uv).rgb;
	vec4 ripples = texture(ripples_tex, UV * ripples_radius);
	ripples *= ripples.a;
	float threshold = fract(-TIME + distortion * ripples_radius * 0.1 + noise * ripples_radius * 0.1);
	ripples *= step(threshold, ripples) * step(ripples.r, threshold + ripples_width) * ripples_mult;
	//uv = world_position.xz * 0.025 + TIME * water_speed * 2.0 * -wind_direction;
	//normal += texture(normal_map, (uv + distortion) * (wind_direction + 0.5) * 0.25 + distortion).rgb * (1.0-small_normal_map_weigth);
	ALBEDO = mix(color.rgb + noise + clouds + height + ripples.rgb, color.rgb, value);
	ALBEDO = clamp(ALBEDO, 0, 1);
	NORMAL_MAP = mix(normal, NORMAL_MAP, value);
	ROUGHNESS = roughness;
}
