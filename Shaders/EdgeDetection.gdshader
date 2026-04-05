shader_type spatial;
render_mode unshaded, shadows_disabled;


global uniform sampler2D clouds_tex : filter_linear_mipmap;

group_uniforms Edges;
uniform float depth_threshold : hint_range(0.001,1.0,0.01) = 0.2f;
uniform float depth_normal_threshold_scale : hint_range(0.0,150.0,0.01) = 0.2f;
uniform float normal_threshold : hint_range(0.0,10.0,0.01) = 0.2f;
uniform vec4 edge_color: source_color;
uniform float edge_scale : hint_range(0.0,10.0) = 0.2f;
group_uniforms;
group_uniforms Watercolor;
uniform sampler2D watercolor_noise_tex;
uniform float watercolor_visibility : hint_range(0.0,1.0) = 0.2f;
uniform float watercolor_strength : hint_range(0.0,1.0) = 0.2f;
uniform float watercolor_speed = 0.0f;
uniform float color_variation = 0.0f;
group_uniforms;
group_uniforms Fog;
uniform sampler2D fog_color_ramp;
uniform sampler2D fog_noise_tex;
uniform float fog_height;
uniform float fog_smoothness;
group_uniforms;
group_uniforms Clouds;
uniform float clouds_strength;
uniform float clouds_height;
uniform float clouds_smoothness;
uniform vec3 clouds_color: source_color;
group_uniforms;
//group_uniforms Rain;
//uniform vec3 rain_color : source_color;
//group_uniforms;
group_uniforms Sun;
uniform vec3 sun_color : source_color;
uniform vec3 sun_dir;
uniform float sun_power;
group_uniforms;
group_uniforms Vignette;
uniform float vignette_threshold;
uniform float vignette_smoothness;
group_uniforms;
group_uniforms ImpactCircle;
uniform float impact : hint_range(0.0, 1.0, 0.01);
uniform float impact_magnitude : hint_range(0.0, 1.0, 0.01);
uniform vec2 impact_pos;
uniform float deformation_strength;
uniform float screenshake_magnitude;
uniform float screenshake_speed;
uniform vec3 vignette_impact_color: source_color;
uniform float zoom_magnitude;
uniform float dead : hint_range(0.0, 1.0, 0.01);
uniform vec3 dead_color : source_color;
uniform vec4 aux;
group_uniforms;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D NORMAL_TEXTURE : hint_normal_roughness_texture, repeat_disable, filter_nearest;


void fragment() {
	vec2 zoomed_uv = SCREEN_UV * zoom_magnitude - zoom_magnitude * 0.5 + 0.5;
	float real_impact = impact * impact_magnitude;
	zoomed_uv = mix(SCREEN_UV, zoomed_uv, real_impact + dead);
	//zoomed_uv = mix(SCREEN_UV, zoomed_uv, real_impact);
	vec4 screen = texture(SCREEN_TEXTURE, zoomed_uv);
	vec2 SCREEN_PIXEL_SIZE = 1.0 / VIEWPORT_SIZE;
	// EDGES
    float half_scale_floor = floor(edge_scale * 0.5);
    float half_scale_ceil = ceil(edge_scale * 0.5);
	// Flip UV on Y axis
	vec2 uv = zoomed_uv;
	uv.x += real_impact * sin(TIME * screenshake_speed + 25.3) * 0.1 * screenshake_magnitude;
	uv.y += real_impact * cos(TIME * screenshake_speed + 337.8) * 0.1 * screenshake_magnitude;
	vec2 bottom_left_UV = uv + vec2(SCREEN_PIXEL_SIZE.x, SCREEN_PIXEL_SIZE.y) * half_scale_floor;
	vec2 top_right_UV =  uv + vec2(SCREEN_PIXEL_SIZE.x, SCREEN_PIXEL_SIZE.y) * half_scale_ceil;
	vec2 bottom_right_UV =  uv + vec2(SCREEN_PIXEL_SIZE.x * half_scale_ceil, -SCREEN_PIXEL_SIZE.y * half_scale_floor);
	vec2 top_left_UV =  uv + vec2(-SCREEN_PIXEL_SIZE.x * half_scale_floor, SCREEN_PIXEL_SIZE.y * half_scale_ceil);
	// Sample depths
	float depth0 = texture(DEPTH_TEXTURE, bottom_left_UV).r;
	float depth1 = texture(DEPTH_TEXTURE, top_right_UV).r;
	float depth2 = texture(DEPTH_TEXTURE, bottom_right_UV).r;
	float depth3 = texture(DEPTH_TEXTURE, top_left_UV).r;
	float depth_finite_difference_0 = depth1 - depth0;
	float depth_finite_difference_1 = depth3 - depth2;
	float edge_depth = sqrt(pow(depth_finite_difference_0, 2) + pow(depth_finite_difference_1, 2)) * 1.0;
	// Sample normals
	vec3 normal0 = texture(NORMAL_TEXTURE, bottom_left_UV).rgb;
	vec3 normal1 = texture(NORMAL_TEXTURE, top_right_UV).rgb;
	vec3 normal2 = texture(NORMAL_TEXTURE, bottom_right_UV).rgb;
	vec3 normal3 = texture(NORMAL_TEXTURE, top_left_UV).rgb;
	vec3 normal_finite_difference_0 = normal1 - normal0;
	vec3 normal_finite_difference_1 = normal3 - normal2;
	vec3 view_normal = normal0 * 2.0 - 1.0;
	float n_dot_v = 1.0 - dot(view_normal, CAMERA_DIRECTION_WORLD);
	float normal_threshold_01 = (n_dot_v - depth_threshold) / (1.0 - depth_threshold);
	float new_normal_threshold = normal_threshold_01 * depth_normal_threshold_scale + 1.0;
	float edge_normal = sqrt(dot(normal_finite_difference_0, normal_finite_difference_0) + dot(normal_finite_difference_1, normal_finite_difference_1));
	edge_normal = edge_normal > normal_threshold ? 1.0 : 0.0;
	// Combination
	edge_depth = edge_depth > depth_threshold * depth0 * new_normal_threshold ? 1.0 : 0.0;
	float edge = max(edge_depth, edge_normal);
	edge = smoothstep(0.9, 0.9, edge);
	// WATERCOLOR EFFECT
	float time_offset = round(TIME)*0.35;
	//float time_offset = TIME * watercolor_speed;
	float d = distance(SCREEN_UV - impact_pos, vec2(0.5));
	float inverse_impact = 1.0-impact;
	float outside_impact_circle = 1.0-smoothstep(0, inverse_impact, d);
	float inside_impact_circle = 1.0-smoothstep(0, inverse_impact * 0.5, d);
	outside_impact_circle -= inside_impact_circle;
	outside_impact_circle = clamp(outside_impact_circle, 0, 1);
	outside_impact_circle *= impact;
	float w_strength = watercolor_strength + outside_impact_circle * deformation_strength * impact_magnitude;
	float noise_watercolor_deformation = (texture(watercolor_noise_tex, fract(SCREEN_UV + time_offset)).r * w_strength) * 2.0 - w_strength;
	float noise_watercolor_deformation_2 = (texture(watercolor_noise_tex, fract(SCREEN_UV * 2.0 - time_offset)).r * w_strength) * 2.0 - w_strength;
	vec2 uv_deformation = vec2(noise_watercolor_deformation, noise_watercolor_deformation_2) * 0.1;
	vec2 uv_deformation_2 = vec2(-noise_watercolor_deformation_2, -noise_watercolor_deformation) * 0.1;
	uv_deformation = uv_deformation * (outside_impact_circle * deformation_strength * impact_magnitude + 1.0);
	uv_deformation_2 = uv_deformation * (outside_impact_circle * deformation_strength * impact_magnitude + 1.0);
	vec4 screen_watercolor = textureLod(SCREEN_TEXTURE, zoomed_uv + uv_deformation + uv_deformation_2, 2.0);
	float contrast_weight = max(1, (length(uv_deformation) + length(uv_deformation_2)) * color_variation);
	//screen_watercolor.rgb = pow(screen_watercolor.rgb, min(vec3(2.0) * (abs(noise_watercolor_deformation) / watercolor_strength), vec3(1.0)));
	screen_watercolor.rgb = pow(screen_watercolor.rgb, vec3(contrast_weight));
	// FOG
	//float depth = (depth1 + depth3) / 2.0; // An aproximation so i dont need to sample again the tex
	float depth = (depth0 + depth2) / 2.0; // An aproximation so i dont need to sample again the tex
	//float depth = (depth0 + depth1 + depth2 + depth3) / 4.0; // An aproximation so i dont need to sample again the tex
	vec3 depth_normalized_device_coordinates = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 depth_view_space = INV_PROJECTION_MATRIX * vec4(depth_normalized_device_coordinates, 1.0);
	depth_view_space.xyz /= depth_view_space.w;
	vec4 depth_world_space = INV_VIEW_MATRIX * depth_view_space;
	float y = smoothstep(0.5 - fog_smoothness, 0.5 + fog_smoothness, depth_world_space.y + fog_height);
	vec2 corrected_uv = SCREEN_UV;
	corrected_uv.x *= VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	vec3 fog_noise = texture(fog_noise_tex, corrected_uv + time_offset).rgb;
	vec3 fog_color = texture(fog_color_ramp, vec2(corrected_uv.y, 0.5)).rgb * fog_noise.rgb;
	// Rain
	//float rain_mult = step(0.9, fract(SCREEN_UV.x * 100.0 * fog_noise.r) * fract(SCREEN_UV.y * 0.5 - TIME * fog_noise.r * 1.0));
	//vec3 rain = rain_color * rain_mult;
	// Final color
	ALBEDO = screen.rgb * (1.0-watercolor_visibility) + screen_watercolor.rgb * watercolor_visibility;
	float grayscale = (ALBEDO.r + ALBEDO.g + ALBEDO.b) / 3.0;
	grayscale = pow(grayscale, aux.y);
	ALBEDO = mix(ALBEDO, vec3(grayscale * aux.x) + dead_color, dead);
	edge *= (noise_watercolor_deformation + w_strength) * 0.5 / w_strength;
	vec3 e_c = mix(edge_color.rgb, vec3(2), dead);
	ALBEDO = mix(ALBEDO, e_c, edge_color.a * edge);
	ALBEDO = mix(fog_color, ALBEDO, y);
	vec4 clouds = textureLod(clouds_tex, SCREEN_UV, 2) * clouds_strength;
	clouds *= clouds_height;
	y = smoothstep(0.5 - clouds_smoothness, 0.5 + clouds_smoothness, depth_world_space.y + clouds_height);
	ALBEDO = mix(ALBEDO, clouds.rgb * clouds_color, clouds.a * y);
	vec3 light_dir = normalize(sun_dir);
	vec3 lighting = pow(max(dot(light_dir, normalize(depth_world_space.xyz-CAMERA_POSITION_WORLD)), 0), sun_power) * sun_color;
	//float vignette = smoothstep(vignette_threshold-vignette_smoothness, vignette_threshold+vignette_smoothness, 1.0-abs(SCREEN_UV.y * 2.0 - 1.0));
	float vignette = smoothstep(vignette_threshold-vignette_smoothness, vignette_threshold+vignette_smoothness, 1.0-distance(SCREEN_UV, vec2(0.5)));
	ALBEDO += lighting;
	ALBEDO *= vignette + vignette_impact_color * real_impact;
	//ALBEDO.rgb = mix(ALBEDO.rgb, vec3(outside_impact_circle), 0.15);
	//ALBEDO.rgb = vec3(outside_impact_circle);
}