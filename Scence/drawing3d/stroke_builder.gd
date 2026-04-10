# stroke_builder.gd
class_name StrokeBuilder
extends Node

# ── StrokeData: lưu đủ thông tin để rebuild mesh sau khi erase ──
class StrokeData:
	var mesh_inst:       MeshInstance3D  = null
	var stamp_positions: Array[Vector3]  = []
	var rng_seed:        int             = 0
	var preset:          BrushPreset     = null
	var brush_size:      float           = 0.08
	var thickness:       float           = 0.5
	var opacity:         float           = 1.0   # snapshot opacity tại thời điểm vẽ
	var spacing:         float           = 0.016
	var color:           Color           = Color.BLACK
	var plane_right:     Vector3         = Vector3.ZERO
	var plane_up:        Vector3         = Vector3.ZERO
	var plane_normal:    Vector3         = Vector3.ZERO
	var render_order:    int             = 0

@export var brushes:         Array[BrushPreset] = []
var current_brush_index:     int                = 0
var current_color:           Color              = Color.BLACK

const MIN_DIST := 0.003

var _stroke_counter: int = 0

var _points:        Array[Vector3] = []
var _camera:        Camera3D       = null
var _plane_normal:  Vector3        = Vector3.ZERO
var _plane_right:   Vector3        = Vector3.ZERO
var _plane_up:      Vector3        = Vector3.ZERO
var _preview_inst:  MeshInstance3D = null
var _parent:        Node3D         = null
var _rng:           RandomNumberGenerator = RandomNumberGenerator.new()

# ── Preview incremental — chỉ append, không rebuild toàn bộ ──
var _preview_verts:   PackedVector3Array = PackedVector3Array()
var _preview_normals: PackedVector3Array = PackedVector3Array()
var _preview_uvs:     PackedVector2Array = PackedVector2Array()
var _preview_colors:  PackedColorArray   = PackedColorArray()
var _preview_stamp_positions: Array[Vector3] = []
var _preview_accumulated: float = 0.0
var _preview_rng:     RandomNumberGenerator = RandomNumberGenerator.new()
var _preview_preset:    BrushPreset = null
var _preview_size:      float = 0.08
var _preview_thickness: float = 0.2
var _preview_opacity:   float = 1.0
var _preview_spacing:   float = 0.016

func setup(camera: Camera3D, parent: Node3D, plane: DrawingPlane = null) -> void:
	_camera = camera
	_parent = parent
	if plane != null:
		_plane_right  =  plane.global_basis.x
		_plane_up     =  plane.global_basis.y
		_plane_normal = -plane.global_basis.z
	else:
		_plane_right  =  camera.global_basis.x
		_plane_up     =  camera.global_basis.y
		_plane_normal = -camera.global_basis.z

func get_current_preset() -> BrushPreset:
	if brushes.is_empty():
		return null
	return brushes[clamp(current_brush_index, 0, brushes.size() - 1)]

func start_stroke(world_point: Vector3) -> void:
	_points.clear()
	_points.append(world_point)
	_rng.randomize()

	# Reset preview incremental state
	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()
	_preview_stamp_positions.clear()
	_preview_accumulated = 0.0

	_preview_preset    = get_current_preset()
	_preview_size      = _preview_preset.brush_size      if _preview_preset else 0.08
	_preview_thickness = _preview_preset.thickness       if _preview_preset else 0.5
	_preview_opacity   = _preview_preset.opacity         if _preview_preset else 1.0
	_preview_spacing   = _preview_size * (_preview_preset.spacing_percent if _preview_preset else 0.2)
	_preview_spacing   = maxf(_preview_spacing, MIN_DIST)

	# Seed RNG preview cùng seed với stroke thật
	_preview_rng.seed = _rng.seed

	# Stamp điểm đầu tiên
	_append_stamps_for_segment(world_point, world_point, true)

	if _preview_inst != null:
		_preview_inst.queue_free()
	_preview_inst           = MeshInstance3D.new()
	_preview_inst.top_level = true
	_parent.add_child(_preview_inst)

func add_point(world_point: Vector3) -> void:
	if _points.is_empty():
		return
	if world_point.distance_to(_points.back()) < MIN_DIST:
		return
	var prev = _points.back()
	_points.append(world_point)

	# Chỉ append stamps của segment MỚI — không rebuild toàn bộ
	_append_stamps_for_segment(prev, world_point, false)
	_flush_preview_mesh()

# Tính stamp positions cho 1 segment và append verts vào buffer
func _append_stamps_for_segment(from: Vector3, to: Vector3, is_first: bool) -> void:
	if is_first:
		# Điểm đầu tiên: đặt 1 stamp tại vị trí đó
		_preview_stamp_positions.append(from)
		_append_stamp_verts(from, _preview_rng)
		return

	var seg_len := from.distance_to(to)
	if seg_len < 0.0001:
		return

	_preview_accumulated += seg_len
	while _preview_accumulated >= _preview_spacing:
		_preview_accumulated -= _preview_spacing
		var t   := (seg_len - _preview_accumulated) / seg_len
		var pos := from.lerp(to, t)
		_preview_stamp_positions.append(pos)
		_append_stamp_verts(pos, _preview_rng)

func _append_stamp_verts(pos: Vector3, rng: RandomNumberGenerator) -> void:
	var preset    := _preview_preset
	var size      := _preview_size
	var thickness := _preview_thickness
	var pr        := _plane_right
	var pu        := _plane_up
	var pn        := _plane_normal

	var stamp_angle   := rng.randf_range(-1.0, 1.0) * (preset.angle_jitter   if preset else 0.0)
	var stamp_scale   := 1.0 + rng.randf_range(-1.0, 1.0) * (preset.size_jitter    if preset else 0.1)
	var stamp_opacity := clampf(
		1.0 + rng.randf_range(-1.0, 1.0) * (preset.opacity_jitter if preset else 0.1),
		0.0, 1.0
	)
	var scatter_offset := Vector3.ZERO
	if preset and preset.scatter > 0.0:
		scatter_offset = (
			pr * rng.randf_range(-1.0, 1.0) +
			pu * rng.randf_range(-1.0, 1.0)
		) * preset.scatter * size

	var half_w := size * stamp_scale * 0.5
	var half_d := half_w * thickness
	var center := pos + scatter_offset

	var cos_a := cos(stamp_angle)
	var sin_a := sin(stamp_angle)
	var r     := (pr * cos_a + pu * sin_a).normalized()
	var u     := (pr * (-sin_a) + pu * cos_a).normalized()
	var fwd   := pn

	var col := Color(
		current_color.r, current_color.g, current_color.b,
		current_color.a * _preview_opacity * stamp_opacity
	)

	var ftl := center + u * half_w - r * half_w + fwd * half_d
	var ftr := center + u * half_w + r * half_w + fwd * half_d
	var fbl := center - u * half_w - r * half_w + fwd * half_d
	var fbr := center - u * half_w + r * half_w + fwd * half_d
	var btl := center + u * half_w - r * half_w - fwd * half_d
	var btr := center + u * half_w + r * half_w - fwd * half_d
	var bbl := center - u * half_w - r * half_w - fwd * half_d
	var bbr := center - u * half_w + r * half_w - fwd * half_d

	var n_front := fwd;  var n_back   := -fwd
	var n_top   := u;    var n_bottom := -u
	var n_left  := -r;   var n_right2 :=  r

	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbl, fbr, ftr, ftl, n_front,  col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, bbr, bbl, btl, btr, n_back,   col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, ftl, ftr, btr, btl, n_top,    col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbr, fbl, bbl, bbr, n_bottom, col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbl, ftl, btl, bbl, n_left,   col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbr, bbr, btr, ftr, n_right2, col)

# Upload buffer lên GPU — chỉ gọi khi có stamp mới
func _flush_preview_mesh() -> void:
	if _preview_inst == null or _preview_verts.is_empty():
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _preview_verts
	arrays[Mesh.ARRAY_NORMAL] = _preview_normals
	arrays[Mesh.ARRAY_TEX_UV] = _preview_uvs
	arrays[Mesh.ARRAY_COLOR]  = _preview_colors

	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := _build_material(_preview_preset)
	# Preview luôn render trên tất cả stroke đã bake
	mat.render_priority = _stroke_counter + 1

	_preview_inst.mesh              = amesh
	_preview_inst.material_override = mat

func finish_stroke() -> StrokeData:
	if _points.size() < 2:
		if _preview_inst:
			_preview_inst.queue_free()
			_preview_inst = null
		_points.clear()
		_preview_stamp_positions.clear()
		return null

	# Dùng lại stamp positions đã tính trong preview — không tính lại
	var stamp_positions: Array[Vector3] = []
	stamp_positions.assign(_preview_stamp_positions)

	var mi := _bake_mesh_from_buffers()
	if mi == null:
		_preview_inst.queue_free() if _preview_inst else null
		_preview_inst = null
		_points.clear()
		_preview_stamp_positions.clear()
		return null

	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null

	_stroke_counter += 1
	if mi.material_override:
		mi.material_override.render_priority = _stroke_counter

	var data              := StrokeData.new()
	data.mesh_inst         = mi
	data.stamp_positions   = stamp_positions
	data.rng_seed          = _rng.seed
	data.preset            = _preview_preset
	data.brush_size        = _preview_size
	data.thickness         = _preview_thickness
	data.opacity           = _preview_opacity
	data.spacing           = _preview_spacing
	data.color             = current_color
	data.plane_right       = _plane_right
	data.plane_up          = _plane_up
	data.plane_normal      = _plane_normal
	data.render_order      = _stroke_counter

	_points.clear()
	_preview_stamp_positions.clear()
	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()
	return data

# Đúc mesh cuối từ buffer đã build incremental
func _bake_mesh_from_buffers() -> MeshInstance3D:
	if _preview_verts.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _preview_verts
	arrays[Mesh.ARRAY_NORMAL] = _preview_normals
	arrays[Mesh.ARRAY_TEX_UV] = _preview_uvs
	arrays[Mesh.ARRAY_COLOR]  = _preview_colors

	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi              := MeshInstance3D.new()
	mi.mesh              = amesh
	mi.material_override = _build_material(_preview_preset)
	mi.top_level         = true
	return mi

func cancel_stroke() -> void:
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null
	_points.clear()
	_preview_stamp_positions.clear()
	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()

func is_drawing() -> bool:
	return not _points.is_empty()

# ── Eraser ────────────────────────────────────────────────────
func erase_at(world_point: Vector3, strokes: Array, radius: float) -> void:
	for data in strokes:
		var data_typed := data as StrokeData
		if data_typed == null or data_typed.stamp_positions.is_empty():
			continue

		var before_count := data_typed.stamp_positions.size()

		var kept: Array[Vector3] = []
		for sp in data_typed.stamp_positions:
			if sp.distance_to(world_point) > radius:
				kept.append(sp)

		if kept.size() == before_count:
			continue

		data_typed.stamp_positions = kept

		if data_typed.mesh_inst:
			data_typed.mesh_inst.queue_free()
			data_typed.mesh_inst = null

		if kept.size() >= 1:
			var mi := _build_mesh_from_stamps(
				kept,
				data_typed.preset,
				data_typed.rng_seed,
				data_typed.plane_right,
				data_typed.plane_up,
				data_typed.plane_normal,
				data_typed.color,
				data_typed.brush_size,
				data_typed.thickness,
				data_typed.opacity
			)
			if mi:
				if mi.material_override:
					mi.material_override.render_priority = data_typed.render_order
				data_typed.mesh_inst = mi
				_parent.add_child(mi)

# ── Build mesh từ stamp positions (dùng cho erase rebuild) ───
func _build_mesh_from_stamps(
	stamp_positions: Array,
	preset:          BrushPreset,
	rng_seed:        int,
	p_right:         Vector3 = Vector3.ZERO,
	p_up:            Vector3 = Vector3.ZERO,
	p_normal:        Vector3 = Vector3.ZERO,
	col_override:    Color   = Color(-1, 0, 0),
	size_override:   float   = -1.0,
	thick_override:  float   = -1.0,
	opacity_override: float  = -1.0   # -1 = đọc từ preset
) -> MeshInstance3D:
	if stamp_positions.is_empty():
		return null

	var pr := p_right  if p_right  != Vector3.ZERO else _plane_right
	var pu := p_up     if p_up     != Vector3.ZERO else _plane_up
	var pn := p_normal if p_normal != Vector3.ZERO else _plane_normal
	var base_color := col_override if col_override.r >= 0.0 else current_color

	var size      := size_override    if size_override    >= 0.0 else (preset.brush_size if preset else 0.08)
	var thickness := thick_override   if thick_override   >= 0.0 else (preset.thickness  if preset else 0.5)
	var opacity   := opacity_override if opacity_override >= 0.0 else (preset.opacity    if preset else 1.0)

	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var colors  := PackedColorArray()

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	for pos in stamp_positions:
		var stamp_angle   := rng.randf_range(-1.0, 1.0) * (preset.angle_jitter   if preset else 0.0)
		var stamp_scale   := 1.0 + rng.randf_range(-1.0, 1.0) * (preset.size_jitter    if preset else 0.1)
		var stamp_opacity := clampf(
			1.0 + rng.randf_range(-1.0, 1.0) * (preset.opacity_jitter if preset else 0.1),
			0.0, 1.0
		)
		var scatter_offset := Vector3.ZERO
		if preset and preset.scatter > 0.0:
			scatter_offset = (
				pr * rng.randf_range(-1.0, 1.0) +
				pu * rng.randf_range(-1.0, 1.0)
			) * preset.scatter * size

		var half_w := size * stamp_scale * 0.5
		var half_d := half_w * thickness
		var center = pos + scatter_offset

		var cos_a := cos(stamp_angle)
		var sin_a := sin(stamp_angle)
		var r     := (pr * cos_a + pu * sin_a).normalized()
		var u     := (pr * (-sin_a) + pu * cos_a).normalized()
		var fwd   := pn

		var col := Color(
			base_color.r, base_color.g, base_color.b,
			base_color.a * opacity * stamp_opacity
		)

		var ftl = center + u * half_w - r * half_w + fwd * half_d
		var ftr = center + u * half_w + r * half_w + fwd * half_d
		var fbl = center - u * half_w - r * half_w + fwd * half_d
		var fbr = center - u * half_w + r * half_w + fwd * half_d
		var btl = center + u * half_w - r * half_w - fwd * half_d
		var btr = center + u * half_w + r * half_w - fwd * half_d
		var bbl = center - u * half_w - r * half_w - fwd * half_d
		var bbr = center - u * half_w + r * half_w - fwd * half_d

		var n_front := fwd;  var n_back   := -fwd
		var n_top   := u;    var n_bottom := -u
		var n_left  := -r;   var n_right2 :=  r

		_add_quad(verts, normals, uvs, colors, fbl, fbr, ftr, ftl, n_front,  col)
		_add_quad(verts, normals, uvs, colors, bbr, bbl, btl, btr, n_back,   col)
		_add_quad(verts, normals, uvs, colors, ftl, ftr, btr, btl, n_top,    col)
		_add_quad(verts, normals, uvs, colors, fbr, fbl, bbl, bbr, n_bottom, col)
		_add_quad(verts, normals, uvs, colors, fbl, ftl, btl, bbl, n_left,   col)
		_add_quad(verts, normals, uvs, colors, fbr, bbr, btr, ftr, n_right2, col)

	if verts.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR]  = colors

	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi              := MeshInstance3D.new()
	mi.mesh              = amesh
	mi.material_override = _build_material(preset)
	mi.top_level         = true
	return mi

# Helper — add 1 quad
func _add_quad(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	uvs:     PackedVector2Array,
	colors:  PackedColorArray,
	bl: Vector3, br: Vector3, tr: Vector3, tl: Vector3,
	normal: Vector3, col: Color
) -> void:
	verts.append(bl);  normals.append(normal); uvs.append(Vector2(0,1)); colors.append(col)
	verts.append(br);  normals.append(normal); uvs.append(Vector2(1,1)); colors.append(col)
	verts.append(tr);  normals.append(normal); uvs.append(Vector2(1,0)); colors.append(col)
	verts.append(bl);  normals.append(normal); uvs.append(Vector2(0,1)); colors.append(col)
	verts.append(tr);  normals.append(normal); uvs.append(Vector2(1,0)); colors.append(col)
	verts.append(tl);  normals.append(normal); uvs.append(Vector2(0,0)); colors.append(col)

func _build_material(preset: BrushPreset) -> ShaderMaterial:
	var mat   := ShaderMaterial.new()
	mat.shader = _create_shader()

	if preset and preset.brush_texture != null:
		mat.set_shader_parameter("brush_tex",     preset.brush_texture)
		mat.set_shader_parameter("use_brush_tex", true)
	else:
		mat.set_shader_parameter("use_brush_tex", false)

	return mat

func _create_shader() -> Shader:
	var s  := Shader.new()
	s.code  = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;

uniform sampler2D brush_tex : filter_linear_mipmap, repeat_disable, hint_default_white;
uniform bool use_brush_tex  = false;

void fragment() {
	vec3 c = COLOR.rgb;
	vec3 linear_color = mix(
		c / 12.92,
		pow((c + 0.055) / 1.055, vec3(2.4)),
		step(0.04045, c)
	);

	// Tính góc giữa normal của mặt và hướng camera (view space)
	// NORMAL trong view space — Z = hướng về camera
	float facing = abs(dot(normalize(NORMAL), vec3(0.0, 0.0, 1.0)));

	// Discard mặt gần vuông góc với camera (facing < threshold)
	if (facing < 0.15) discard;

	// Mờ dần khi mặt nghiêng, đậm khi nhìn thẳng
	float face_alpha = smoothstep(0.15, 0.5, facing);

	float alpha = COLOR.a * face_alpha;
	if (use_brush_tex) {
		vec4  brush    = texture(brush_tex, UV);
		float lum      = dot(brush.rgb, vec3(0.299, 0.587, 0.114));
		float darkness = 1.0 - lum;
		alpha *= darkness * brush.a;
	}

	ALBEDO = linear_color;
	ALPHA  = clamp(alpha, 0.0, 1.0);
}
"""
	return s
