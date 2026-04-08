# stroke_builder.gd
class_name StrokeBuilder
extends Node

@export var brushes:         Array[BrushPreset] = []
var current_brush_index:     int                = 0
var current_color:           Color              = Color.BLACK

const MIN_DIST := 0.003

var _points:       Array[Vector3] = []
var _camera:       Camera3D       = null
var _cam_forward:  Vector3        = Vector3.ZERO
var _cam_right:    Vector3        = Vector3.ZERO
var _cam_up:       Vector3        = Vector3.ZERO
var _preview_inst: MeshInstance3D = null
var _parent:       Node3D         = null
var _rng:          RandomNumberGenerator = RandomNumberGenerator.new()

func setup(camera: Camera3D, parent: Node3D) -> void:
	_camera = camera
	_parent = parent

func get_current_preset() -> BrushPreset:
	if brushes.is_empty():
		return null
	return brushes[clamp(current_brush_index, 0, brushes.size() - 1)]

func start_stroke(world_point: Vector3) -> void:
	_points.clear()
	_points.append(world_point)
	_cam_forward = -_camera.global_basis.z
	_cam_right   =  _camera.global_basis.x
	_cam_up      =  _camera.global_basis.y
	_rng.randomize()

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
	_points.append(world_point)
	_update_preview()

func finish_stroke() -> MeshInstance3D:
	if _points.size() < 2:
		if _preview_inst:
			_preview_inst.queue_free()
			_preview_inst = null
		_points.clear()
		return null
	var baked := _build_stamp_mesh(_points)
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null
	_points.clear()
	return baked

func cancel_stroke() -> void:
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null
	_points.clear()

func is_drawing() -> bool:
	return not _points.is_empty()

func _update_preview() -> void:
	if _preview_inst == null or _points.size() < 2:
		return
	var built := _build_stamp_mesh(_points)
	if built:
		_preview_inst.mesh              = built.mesh
		_preview_inst.material_override = built.material_override
		built.queue_free()

func _build_stamp_mesh(points: Array) -> MeshInstance3D:
	if points.size() < 2:
		return null

	var preset    := get_current_preset()
	var size      := preset.brush_size      if preset else 0.08
	var thickness := preset.thickness       if preset else 0.5
	var spacing   := size * (preset.spacing_percent if preset else 0.2)
	spacing        = maxf(spacing, MIN_DIST)

	# ── Tính stamp positions dọc theo path ───────────────────
	var stamp_positions : Array[Vector3] = []
	stamp_positions.append(points[0])
	var accumulated := 0.0

	for i in range(1, points.size()):
		var seg_len = points[i].distance_to(points[i-1])
		accumulated  += seg_len
		while accumulated >= spacing:
			accumulated -= spacing
			var t   = (seg_len - accumulated) / seg_len
			var pos = points[i-1].lerp(points[i], t)
			stamp_positions.append(pos)

	if stamp_positions.is_empty():
		return null

	# ── Build box stamps ──────────────────────────────────────
	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var colors  := PackedColorArray()

	var rng := RandomNumberGenerator.new()
	rng.seed = _rng.seed

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
				_cam_right * rng.randf_range(-1.0, 1.0) +
				_cam_up    * rng.randf_range(-1.0, 1.0)
			) * preset.scatter * size

		var half_w := size * stamp_scale * 0.5
		var half_d := half_w * thickness
		var center := pos + scatter_offset

		var cos_a := cos(stamp_angle)
		var sin_a := sin(stamp_angle)
		var r     := (_cam_right * cos_a + _cam_up * sin_a).normalized()
		var u     := (_cam_right * (-sin_a) + _cam_up * cos_a).normalized()
		var fwd   := _cam_forward

		var col := Color(
			current_color.r, current_color.g, current_color.b,
			current_color.a * (preset.opacity if preset else 1.0) * stamp_opacity
		)

		# 8 corners
		var ftl := center + u * half_w - r * half_w + fwd * half_d
		var ftr := center + u * half_w + r * half_w + fwd * half_d
		var fbl := center - u * half_w - r * half_w + fwd * half_d
		var fbr := center - u * half_w + r * half_w + fwd * half_d
		var btl := center + u * half_w - r * half_w - fwd * half_d
		var btr := center + u * half_w + r * half_w - fwd * half_d
		var bbl := center - u * half_w - r * half_w - fwd * half_d
		var bbr := center - u * half_w + r * half_w - fwd * half_d

		# Normal của từng mặt (world space)
		var n_front  :=  fwd
		var n_back   := -fwd
		var n_top    :=  u
		var n_bottom := -u
		var n_left   := -r
		var n_right  :=  r

		# Helper để add 1 quad (2 triangles) với normal cố định
		# Front
		_add_quad(verts, normals, uvs, colors,
			fbl, fbr, ftr, ftl, n_front, col)
		# Back
		_add_quad(verts, normals, uvs, colors,
			bbr, bbl, btl, btr, n_back, col)
		# Top
		_add_quad(verts, normals, uvs, colors,
			ftl, ftr, btr, btl, n_top, col)
		# Bottom
		_add_quad(verts, normals, uvs, colors,
			fbr, fbl, bbl, bbr, n_bottom, col)
		# Left
		_add_quad(verts, normals, uvs, colors,
			fbl, ftl, btl, bbl, n_left, col)
		# Right
		_add_quad(verts, normals, uvs, colors,
			fbr, bbr, btr, ftr, n_right, col)

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

	var mat := _build_material(preset)

	var mi              := MeshInstance3D.new()
	mi.mesh              = amesh
	mi.material_override = mat
	mi.top_level         = true
	return mi

# Helper — add 1 quad với 4 corners và 1 normal
func _add_quad(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	uvs:     PackedVector2Array,
	colors:  PackedColorArray,
	bl: Vector3, br: Vector3, tr: Vector3, tl: Vector3,
	normal: Vector3,
	col: Color
) -> void:
	# Triangle 1
	verts.append(bl);  normals.append(normal); uvs.append(Vector2(0,1)); colors.append(col)
	verts.append(br);  normals.append(normal); uvs.append(Vector2(1,1)); colors.append(col)
	verts.append(tr);  normals.append(normal); uvs.append(Vector2(1,0)); colors.append(col)
	# Triangle 2
	verts.append(bl);  normals.append(normal); uvs.append(Vector2(0,1)); colors.append(col)
	verts.append(tr);  normals.append(normal); uvs.append(Vector2(1,0)); colors.append(col)
	verts.append(tl);  normals.append(normal); uvs.append(Vector2(0,0)); colors.append(col)

func _build_material(preset: BrushPreset) -> ShaderMaterial:
	var mat    := ShaderMaterial.new()
	mat.shader          = _create_shader()
	mat.render_priority = 1

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

	ALBEDO = COLOR.rgb;
	ALPHA  = clamp(alpha, 0.0, 1.0);
}
"""
	return s
