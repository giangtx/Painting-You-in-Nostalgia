shader_type spatial;


uniform sampler2D color_ramp_tex;
//uniform float roughness;
uniform sampler2D lines_noise_tex;
uniform sampler2D lines_noise_tex2;
uniform sampler2D watercolor_tex;
uniform float watercolor_strength;
uniform sampler2D normal_map : hint_normal;
uniform vec4 lines_color : source_color;

varying vec3 local_position;
varying vec3 world_position;
varying vec3 local_normal;
varying vec3 normal;


void vertex() {
	local_position = VERTEX.xyz;
    world_position = NODE_POSITION_WORLD.xyz + VERTEX.xyz;
	local_normal = (MODEL_NORMAL_MATRIX * NORMAL.rgb).rgb;
	normal = NORMAL;
	//normal = local_position - (local_position + vec3(0.0, 0.0, 1.0));
}

void fragment() {

	//vec4 projected_coords = INV_VIEW_MATRIX * vec4(VERTEX, 1.0);
	//vec3 albedoX = texture(grid_texture, projected_coords.zy).rgb;
	//vec3 albedoY = texture(grid_texture, projected_coords.xz).rgb;
	//vec3 albedoZ = texture(grid_texture, projected_coords.xy).rgb;
	//vec3 world_normal = abs(INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	//vec3 normal_weights = world_normal / (world_normal.x + world_normal.y + world_normal.z);
	//
	//ALBEDO = albedoX * normal_weights.x + albedoY * normal_weights.y + albedoZ * normal_weights.z;

	vec4 color_ramp = texture(color_ramp_tex, sin(vec2(world_position.y * 0.1, 0.0) * 0.5 + 0.5));
	vec2 xy_uvs = vec2(fract(world_position.xy * 0.1));
	vec2 xz_uvs = vec2(fract(world_position.xz * 0.1));
	vec2 zy_uvs = vec2(fract(world_position.zy * 0.1));
	vec3 world_normal = abs(INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vec3 normal_weights = world_normal / (world_normal.x + world_normal.y + world_normal.z);
	vec4 lines_x = texture(lines_noise_tex, xy_uvs);
	vec4 lines_y = texture(lines_noise_tex, xz_uvs);
	vec4 lines_z = texture(lines_noise_tex, zy_uvs);
	//lines_x = (lines_x + lines_z) * 0.5;
	lines_x = lines_x * normal_weights.z + lines_z * normal_weights.x + lines_y * normal_weights.y;
	vec4 lines_x2 = texture(lines_noise_tex2, xy_uvs);
	vec4 lines_y2 = texture(lines_noise_tex2, xz_uvs);
	vec4 lines_z2 = texture(lines_noise_tex2, zy_uvs);
	//lines_x2 = (lines_x2 + lines_z2) * 0.5;
	lines_x2 = lines_x2 * normal_weights.z + lines_z2 * normal_weights.x + lines_y2 * normal_weights.y;
	//lines_x = smoothstep(0, 1, lines_x * lines_x2 + lines_color);
	vec3 watercolor_x = texture(watercolor_tex, xy_uvs).rgb;
	vec3 watercolor_y = texture(watercolor_tex, xz_uvs).rgb;
	vec3 watercolor_z = texture(watercolor_tex, zy_uvs).rgb;
	//watercolor_x = (watercolor_x + watercolor_z) * 0.5;
	watercolor_x = watercolor_x * normal_weights.z + watercolor_z * normal_weights.x + watercolor_y * normal_weights.y;
	watercolor_x = pow(watercolor_x, vec3(watercolor_strength));
	ALBEDO = color_ramp.rgb * lines_x.rgb * lines_x2.rgb * watercolor_x;
	//ALBEDO = color_ramp.rgb * watercolor_x;
	vec3 normal_x = texture(normal_map, xy_uvs).rgb;
	vec3 normal_y = texture(normal_map, xz_uvs).rgb;
	vec3 normal_z = texture(normal_map, zy_uvs).rgb;
	//normal_x = (normal_x + normal_z) * 0.5;
	normal_x = normal_x * normal_weights.z + normal_z * normal_weights.x + normal_y * normal_weights.y;
	NORMAL_MAP = normal_x;
	//ALBEDO = NORMAL_MAP;
	//ALBEDO = local_normal;
}