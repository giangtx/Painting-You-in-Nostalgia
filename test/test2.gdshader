shader_type spatial;
render_mode depth_draw_always, unshaded, cull_disabled;

uniform vec4 albedo_color : source_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform sampler2D brush_tex : filter_linear_mipmap, repeat_disable, hint_default_white;

void fragment() {
    vec4 brush = texture(brush_tex, UV);
    float lum = dot(brush.rgb, vec3(0.299, 0.587, 0.114));
    float tex_alpha = (1.0 - lum) * brush.a * albedo_color.a;

    // Ma trận Dither 4x4 để mô phỏng độ mờ
    const mat4 dither_table = mat4(
        vec4(0.0625, 0.5625, 0.1875, 0.6875),
        vec4(0.8125, 0.3125, 0.9375, 0.4375),
        vec4(0.25, 0.75, 0.125, 0.625),
        vec4(1.0, 0.5, 0.875, 0.375)
    );
    
    // Lấy tọa độ pixel trên màn hình
    ivec2 pixel_pos = ivec2(FRAGCOORD.xy) % 4;
    float threshold = dither_table[pixel_pos.x][pixel_pos.y];

    ALBEDO = albedo_color.rgb;
    
    // Nếu alpha nhỏ hơn ngưỡng dither thì vứt bỏ pixel đó
    if (tex_alpha < threshold) {
        discard;
    }
}