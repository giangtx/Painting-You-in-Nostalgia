# stroke_builder.gd
class_name StrokeBuilder
extends Node

# ── StrokeData: lưu đủ thông tin để rebuild mesh sau khi erase ──
class StrokeData:
	var mesh_inst:       MeshInstance3D  = null
	var stamp_positions: Array[Vector3]  = []
	# [NEW] Normal tại mỗi stamp — dùng để căn chỉnh stamp theo bề mặt cong
	# Nếu is_surface_normal = false thì tất cả stamp dùng chung plane_normal (STRAIGHT)
	var stamp_normals:   Array[Vector3]  = []
	var is_surface_normal: bool          = false
	var rng_seed:        int             = 0
	var preset:          BrushPreset     = null
	var brush_size:      float           = 0.08
	var thickness:       float           = 0.5
	var opacity:         float           = 1.0
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

# [NEW] Flag: plane này có cần per-stamp normal không (CURVED/CLOSED)
var _use_surface_normal: bool = false

# ── Preview incremental — chỉ append, không rebuild toàn bộ ──
var _preview_verts:   PackedVector3Array = PackedVector3Array()
var _preview_normals: PackedVector3Array = PackedVector3Array()
var _preview_uvs:     PackedVector2Array = PackedVector2Array()
var _preview_colors:  PackedColorArray   = PackedColorArray()
var _preview_stamp_positions: Array[Vector3] = []
# [NEW] Buffer lưu normal tại mỗi stamp trong quá trình preview
var _preview_stamp_normals: Array[Vector3] = []
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
		# [NEW] Kiểm tra loại plane để biết có dùng per-stamp normal không
		_use_surface_normal = plane.is_curved_surface
	else:
		_plane_right  =  camera.global_basis.x
		_plane_up     =  camera.global_basis.y
		_plane_normal = -camera.global_basis.z
		_use_surface_normal = false

func get_current_preset() -> BrushPreset:
	if brushes.is_empty():
		return null
	return brushes[clamp(current_brush_index, 0, brushes.size() - 1)]

# [CHANGED] Thêm tham số hit_normal — normal bề mặt tại điểm chạm
func start_stroke(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	_points.clear()
	_points.append(world_point)
	_rng.randomize()

	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()
	_preview_stamp_positions.clear()
	_preview_stamp_normals.clear()  # [NEW]
	_preview_accumulated = 0.0

	_preview_preset    = get_current_preset()
	_preview_size      = _preview_preset.brush_size      if _preview_preset else 0.08
	_preview_thickness = _preview_preset.thickness       if _preview_preset else 0.5
	_preview_opacity   = _preview_preset.opacity         if _preview_preset else 1.0
	_preview_spacing   = _preview_size * (_preview_preset.spacing_percent if _preview_preset else 0.2)
	_preview_spacing   = maxf(_preview_spacing, MIN_DIST)

	_preview_rng.seed = _rng.seed

	# [CHANGED] Truyền hit_normal vào stamp đầu tiên
	_append_stamps_for_segment(world_point, world_point, true, hit_normal)

	if _preview_inst != null:
		_preview_inst.queue_free()
	_preview_inst           = MeshInstance3D.new()
	_preview_inst.top_level = true
	_parent.add_child(_preview_inst)

# [CHANGED] Thêm hit_normal
func add_point(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	if _points.is_empty():
		return
	if world_point.distance_to(_points.back()) < MIN_DIST:
		return
	var prev = _points.back()
	_points.append(world_point)

	_append_stamps_for_segment(prev, world_point, false, hit_normal)
	_flush_preview_mesh()

# [CHANGED] Thêm hit_normal — dùng để nội suy normal dọc segment
func _append_stamps_for_segment(
	from: Vector3, to: Vector3, is_first: bool,
	hit_normal: Vector3 = Vector3.ZERO
) -> void:
	if is_first:
		var sn := _resolve_stamp_normal(hit_normal)
		_preview_stamp_positions.append(from)
		_preview_stamp_normals.append(sn)
		_append_stamp_verts(from, sn, _preview_rng)
		return

	var seg_len := from.distance_to(to)
	if seg_len < 0.0001:
		return

	# Normal của segment này = hit_normal tại điểm "to"
	# Nội suy từ normal stamp cuối → hit_normal hiện tại
	var prev_normal = _preview_stamp_normals.back() if not _preview_stamp_normals.is_empty() \
					  else _resolve_stamp_normal(hit_normal)

	_preview_accumulated += seg_len
	while _preview_accumulated >= _preview_spacing:
		_preview_accumulated -= _preview_spacing
		var t   := (seg_len - _preview_accumulated) / seg_len
		var pos := from.lerp(to, t)
		# Nội suy smooth normal theo t
		var sn  = prev_normal.slerp(_resolve_stamp_normal(hit_normal), t).normalized()
		_preview_stamp_positions.append(pos)
		_preview_stamp_normals.append(sn)
		_append_stamp_verts(pos, sn, _preview_rng)

# [NEW] Resolve normal: dùng hit_normal nếu là curved surface, ngược lại dùng plane_normal
func _resolve_stamp_normal(hit_normal: Vector3) -> Vector3:
	if _use_surface_normal and hit_normal != Vector3.ZERO:
		return hit_normal.normalized()
	return _plane_normal

# [CHANGED] Thêm stamp_normal vào signature — tính pr/pu/pn từ normal thực
func _append_stamp_verts(
	pos: Vector3, stamp_normal: Vector3,
	rng: RandomNumberGenerator
) -> void:
	var preset    := _preview_preset
	var size      := _preview_size
	var thickness := _preview_thickness

	# [CHANGED] Tính local basis từ stamp_normal thay vì dùng _plane_right/up cố định
	var pr: Vector3
	var pu: Vector3
	var pn: Vector3 = stamp_normal.normalized()

	# Xây right/up vuông góc với pn
	# Chọn reference up tránh degenerate khi pn gần song song với Y
	var ref_up := Vector3.UP if absf(pn.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	pr = ref_up.cross(pn).normalized()
	pu = pn.cross(pr).normalized()

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

	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbl, fbr, ftr, ftl, fwd,  col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, bbr, bbl, btl, btr, -fwd, col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, ftl, ftr, btr, btl, u,    col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbr, fbl, bbl, bbr, -u,   col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbl, ftl, btl, bbl, -r,   col)
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, fbr, bbr, btr, ftr, r,    col)

# Upload buffer lên GPU
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
		_preview_stamp_normals.clear()  # [NEW]
		return null

	var stamp_positions: Array[Vector3] = []
	stamp_positions.assign(_preview_stamp_positions)

	# [NEW] Snapshot normals
	var stamp_normals: Array[Vector3] = []
	stamp_normals.assign(_preview_stamp_normals)

	var mi := _bake_mesh_from_buffers()
	if mi == null:
		_preview_inst.queue_free() if _preview_inst else null
		_preview_inst = null
		_points.clear()
		_preview_stamp_positions.clear()
		_preview_stamp_normals.clear()
		return null

	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null

	_stroke_counter += 1
	if mi.material_override:
		mi.material_override.render_priority = _stroke_counter

	var data                 := StrokeData.new()
	data.mesh_inst            = mi
	data.stamp_positions      = stamp_positions
	data.stamp_normals        = stamp_normals         # [NEW]
	data.is_surface_normal    = _use_surface_normal   # [NEW]
	data.rng_seed             = _rng.seed
	data.preset               = _preview_preset
	data.brush_size           = _preview_size
	data.thickness            = _preview_thickness
	data.opacity              = _preview_opacity
	data.spacing              = _preview_spacing
	data.color                = current_color
	data.plane_right          = _plane_right
	data.plane_up             = _plane_up
	data.plane_normal         = _plane_normal
	data.render_order         = _stroke_counter

	_points.clear()
	_preview_stamp_positions.clear()
	_preview_stamp_normals.clear()  # [NEW]
	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()
	return data

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
	_preview_stamp_normals.clear()  # [NEW]
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

		# [CHANGED] Erase cần giữ sync giữa positions và normals
		var kept_pos:    Array[Vector3] = []
		var kept_nrm:    Array[Vector3] = []
		var has_normals  := data_typed.stamp_normals.size() == data_typed.stamp_positions.size()

		for i in range(data_typed.stamp_positions.size()):
			var sp := data_typed.stamp_positions[i]
			if sp.distance_to(world_point) > radius:
				kept_pos.append(sp)
				if has_normals:
					kept_nrm.append(data_typed.stamp_normals[i])

		if kept_pos.size() == before_count:
			continue

		data_typed.stamp_positions = kept_pos
		if has_normals:
			data_typed.stamp_normals = kept_nrm

		if data_typed.mesh_inst:
			data_typed.mesh_inst.queue_free()
			data_typed.mesh_inst = null

		if kept_pos.size() >= 1:
			var mi := _build_mesh_from_stamps(
				kept_pos,
				kept_nrm if has_normals else [],
				data_typed.is_surface_normal,
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
# [CHANGED] Thêm stamp_normals và is_surface_normal
func _build_mesh_from_stamps(
	stamp_positions:   Array,
	stamp_normals:     Array,       # [NEW] Array[Vector3], có thể empty
	is_surface_normal: bool,        # [NEW]
	preset:            BrushPreset,
	rng_seed:          int,
	p_right:           Vector3 = Vector3.ZERO,
	p_up:              Vector3 = Vector3.ZERO,
	p_normal:          Vector3 = Vector3.ZERO,
	col_override:      Color   = Color(-1, 0, 0),
	size_override:     float   = -1.0,
	thick_override:    float   = -1.0,
	opacity_override:  float   = -1.0
) -> MeshInstance3D:
	if stamp_positions.is_empty():
		return null

	var fallback_normal := p_normal if p_normal != Vector3.ZERO else _plane_normal
	var base_color      := col_override if col_override.r >= 0.0 else current_color
	var size            := size_override    if size_override    >= 0.0 else (preset.brush_size if preset else 0.08)
	var thickness       := thick_override   if thick_override   >= 0.0 else (preset.thickness  if preset else 0.5)
	var opacity         := opacity_override if opacity_override >= 0.0 else (preset.opacity    if preset else 1.0)

	var has_normals := is_surface_normal and stamp_normals.size() == stamp_positions.size()

	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var colors  := PackedColorArray()

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	for i in range(stamp_positions.size()):
		var pos := stamp_positions[i] as Vector3

		# [CHANGED] Lấy normal per-stamp hoặc fallback về plane_normal
		var sn: Vector3
		if has_normals:
			sn = (stamp_normals[i] as Vector3).normalized()
		else:
			sn = fallback_normal.normalized()

		# Tính basis từ sn
		var ref_up := Vector3.UP if absf(sn.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var pr     := ref_up.cross(sn).normalized()
		var pu     := sn.cross(pr).normalized()
		var pn     := sn

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

		_add_quad(verts, normals, uvs, colors, fbl, fbr, ftr, ftl, fwd,  col)
		_add_quad(verts, normals, uvs, colors, bbr, bbl, btl, btr, -fwd, col)
		_add_quad(verts, normals, uvs, colors, ftl, ftr, btr, btl, u,    col)
		_add_quad(verts, normals, uvs, colors, fbr, fbl, bbl, bbr, -u,   col)
		_add_quad(verts, normals, uvs, colors, fbl, ftl, btl, bbl, -r,   col)
		_add_quad(verts, normals, uvs, colors, fbr, bbr, btr, ftr, r,    col)

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

	float facing = abs(dot(normalize(NORMAL), vec3(0.0, 0.0, 1.0)));

	if (facing < 0.15) discard;

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
