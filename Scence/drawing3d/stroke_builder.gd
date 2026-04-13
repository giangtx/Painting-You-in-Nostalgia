# stroke_builder.gd
class_name StrokeBuilder
extends Node

# ── StrokeData ───────────────────────────────────────────────
class StrokeData:
	var mesh_inst:         MeshInstance3D = null
	# Stamp positions lưu theo LOCAL SPACE của stroke_container
	# → mesh tự follow khi DrawingPlane transform thay đổi
	var stamp_positions:   Array[Vector3] = []
	var stamp_normals:     Array[Vector3] = []   # local space normals
	var is_surface_normal: bool           = false
	var rng_seed:          int            = 0
	var preset:            BrushPreset    = null
	var brush_size:        float          = 0.08
	var thickness:         float          = 0.5
	var opacity:           float          = 1.0
	var spacing:           float          = 0.016
	var color:             Color          = Color.BLACK
	var plane_right:       Vector3        = Vector3.ZERO  # local space
	var plane_up:          Vector3        = Vector3.ZERO  # local space
	var plane_normal:      Vector3        = Vector3.ZERO  # local space
	var render_order:      int            = 0

@export var brushes:          Array[BrushPreset] = []
var current_brush_index:      int                = 0
var current_color:            Color              = Color.BLACK

const MIN_DIST := 0.003

var _stroke_counter: int = 0

var _points:       Array[Vector3] = []
var _camera:       Camera3D       = null
var _plane:        DrawingPlane   = null   # ref tới plane hiện tại
var _parent:       Node3D         = null   # stroke_container

# Basis local của plane — dùng để convert world→local
var _plane_normal: Vector3 = Vector3.ZERO
var _plane_right:  Vector3 = Vector3.ZERO
var _plane_up:     Vector3 = Vector3.ZERO
var _use_surface_normal: bool = false

var _preview_inst: MeshInstance3D = null
var _rng:          RandomNumberGenerator = RandomNumberGenerator.new()

# ── Preview incremental buffers (local space) ─────────────────
var _preview_verts:   PackedVector3Array = PackedVector3Array()
var _preview_normals: PackedVector3Array = PackedVector3Array()
var _preview_uvs:     PackedVector2Array = PackedVector2Array()
var _preview_colors:  PackedColorArray   = PackedColorArray()
var _preview_stamp_positions: Array[Vector3] = []  # local space
var _preview_stamp_normals:   Array[Vector3] = []  # local space
var _preview_accumulated: float = 0.0
var _preview_rng:     RandomNumberGenerator = RandomNumberGenerator.new()
var _preview_preset:    BrushPreset = null
var _preview_size:      float = 0.08
var _preview_thickness: float = 0.2
var _preview_opacity:   float = 1.0
var _preview_spacing:   float = 0.016

# ── Setup ─────────────────────────────────────────────────────
func setup(camera: Camera3D, parent: Node3D, plane: DrawingPlane = null) -> void:
	_camera = camera
	_parent = parent
	_plane  = plane
	if plane != null:
		# Lưu basis trong local space của stroke_container (= plane local)
		# stroke_container là child trực tiếp của DrawingPlane nên
		# to_local của stroke_container ≈ to_local của plane
		_plane_right  =  plane.global_basis.x
		_plane_up     =  plane.global_basis.y
		_plane_normal = -plane.global_basis.z
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

# ── Helpers: world ↔ local ────────────────────────────────────
func _to_local(world_pos: Vector3) -> Vector3:
	if _parent == null:
		return world_pos
	return _parent.to_local(world_pos)

func _local_normal_to_world(local_n: Vector3) -> Vector3:
	if _parent == null:
		return local_n
	# Rotate-only transform (không scale)
	return _parent.global_basis * local_n

func _world_normal_to_local(world_n: Vector3) -> Vector3:
	if _parent == null:
		return world_n
	return _parent.global_basis.inverse() * world_n

# ── Stroke start ──────────────────────────────────────────────
func start_stroke(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	_points.clear()
	_points.append(world_point)
	_rng.randomize()

	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()
	_preview_stamp_positions.clear()
	_preview_stamp_normals.clear()
	_preview_accumulated = 0.0

	_preview_preset    = get_current_preset()
	_preview_size      = _preview_preset.brush_size      if _preview_preset else 0.08
	_preview_thickness = _preview_preset.thickness       if _preview_preset else 0.5
	_preview_opacity   = _preview_preset.opacity         if _preview_preset else 1.0
	_preview_spacing   = _preview_size * (_preview_preset.spacing_percent if _preview_preset else 0.2)
	_preview_spacing   = maxf(_preview_spacing, MIN_DIST)

	_preview_rng.seed = _rng.seed

	if _preview_inst != null:
		_preview_inst.queue_free()
	_preview_inst           = MeshInstance3D.new()
	_preview_inst.top_level = false
	_parent.add_child(_preview_inst)

	# Stamp đầu tiên tại điểm click
	var sn_local  := _resolve_stamp_normal_local(hit_normal)
	var pos_local := _to_local(world_point)
	_preview_stamp_positions.append(pos_local)
	_preview_stamp_normals.append(sn_local)
	_append_stamp_verts(pos_local, sn_local, _preview_rng)
	_preview_accumulated = 0.0
	_flush_preview_mesh()

func add_point(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	if _points.is_empty():
		return
	if world_point.distance_to(_points.back()) < MIN_DIST:
		return
	var prev = _points.back()
	_points.append(world_point)
	_append_stamps_for_segment(prev, world_point, hit_normal)
	_flush_preview_mesh()

# ── Stamp segment ─────────────────────────────────────────────
func _append_stamps_for_segment(
	from: Vector3, to: Vector3,
	hit_normal: Vector3 = Vector3.ZERO
) -> void:
	var seg_len := from.distance_to(to)
	if seg_len < 0.0001:
		return

	var prev_normal_local = _preview_stamp_normals.back() \
		if not _preview_stamp_normals.is_empty() \
		else _resolve_stamp_normal_local(hit_normal)
	var target_normal_local := _resolve_stamp_normal_local(hit_normal)

	_preview_accumulated += seg_len
	while _preview_accumulated >= _preview_spacing:
		_preview_accumulated -= _preview_spacing
		var t         := (seg_len - _preview_accumulated) / seg_len
		var pos_world := from.lerp(to, t)
		var pos_local := _to_local(pos_world)
		var sn_local  = prev_normal_local.slerp(target_normal_local, t).normalized()
		_preview_stamp_positions.append(pos_local)
		_preview_stamp_normals.append(sn_local)
		_append_stamp_verts(pos_local, sn_local, _preview_rng)

# Resolve normal và convert sang local space
func _resolve_stamp_normal_local(hit_normal_world: Vector3) -> Vector3:
	var world_n: Vector3
	if _use_surface_normal and hit_normal_world != Vector3.ZERO:
		world_n = hit_normal_world.normalized()
	else:
		world_n = _plane_normal
	return _world_normal_to_local(world_n).normalized()

# ── Append stamp verts (local space) ─────────────────────────
# pos và stamp_normal đều đã là LOCAL SPACE
func _append_stamp_verts(
	pos_local: Vector3, normal_local: Vector3,
	rng: RandomNumberGenerator
) -> void:
	var preset    := _preview_preset
	var size      := _preview_size
	var thickness := _preview_thickness
	var pn        := normal_local.normalized()

	var ref_up := Vector3.UP if absf(pn.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var pr     := ref_up.cross(pn).normalized()
	var pu     := pn.cross(pr).normalized()

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
	var center := pos_local + scatter_offset

	var cos_a := cos(stamp_angle)
	var sin_a := sin(stamp_angle)
	var r     := (pr * cos_a + pu * sin_a).normalized()
	var u     := (pr * (-sin_a) + pu * cos_a).normalized()

	var col := Color(
		current_color.r, current_color.g, current_color.b,
		current_color.a * _preview_opacity * stamp_opacity
	)

	# --- Quad 1: Nằm ngang (dùng trục r và u) ---
	# Pháp tuyến (normal) hướng theo pn
	var tl1 := center + u * half_w - r * half_w
	var tr1 := center + u * half_w + r * half_w
	var bl1 := center - u * half_w - r * half_w
	var br1 := center - u * half_w + r * half_w
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, bl1, br1, tr1, tl1,  pn, col)
	# Nếu cần Quad 1 cũng thấy được từ bên dưới, bạn mở comment dòng này:
	_add_quad(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, br1, bl1, tl1, tr1, -pn, col)


	var half_d := half_w * thickness

	# --- Quad 2: Dựng đứng (dùng trục u và pn) ---
	# Vuông góc với Quad 1. Pháp tuyến hướng theo r.
	var tl2 := center + u * half_w - pn * half_d
	var tr2 := center + u * half_w + pn * half_d
	var bl2 := center - u * half_w - pn * half_d
	var br2 := center - u * half_w + pn * half_d
	
	# Vẽ 2 mặt trước/sau để không bị tàng hình khi xoay camera
	_add_quad_side(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, bl2, br2, tr2, tl2,  r, col)
	_add_quad_side(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, br2, bl2, tl2, tr2, -r, col)


	# --- Quad 3: Dựng đứng chéo (dùng trục r và pn) ---
	# Vuông góc với CẢ Quad 1 và Quad 2. Pháp tuyến hướng theo u.
	var tl3 := center + r * half_w - pn * half_d
	var tr3 := center + r * half_w + pn * half_d
	var bl3 := center - r * half_w - pn * half_d
	var br3 := center - r * half_w + pn * half_d
	
	# Vẽ 2 mặt trước/sau cho Quad 3
	_add_quad_side(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, bl3, br3, tr3, tl3,  u, col)
	_add_quad_side(_preview_verts, _preview_normals, _preview_uvs, _preview_colors, br3, bl3, tl3, tr3, -u, col)

# ── Flush preview mesh ────────────────────────────────────────
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
	var mat := _build_material(_preview_preset, _plane_normal)
	# Preview luôn hiện trên stroke cuối của plane hiện tại
	var preview_priority := 0
	if _plane != null:
		preview_priority = clampi(_plane._strokes.size(), -127, 127)
	mat.render_priority = preview_priority
	mat.set_shader_parameter("depth_offset", -float(preview_priority) * 0.01)
	_preview_inst.mesh = amesh
	_preview_inst.set_surface_override_material(0, mat)

# ── Finish stroke ─────────────────────────────────────────────
func finish_stroke() -> StrokeData:
	if _points.is_empty():
		if _preview_inst:
			_preview_inst.queue_free()
			_preview_inst = null
		return null

	var stamp_positions: Array[Vector3] = []
	stamp_positions.assign(_preview_stamp_positions)  # already local space
	var stamp_normals: Array[Vector3] = []
	stamp_normals.assign(_preview_stamp_normals)      # already local space

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

	# render_priority được set bởi DrawingPlane.add_stroke() theo index

	# plane_right/up/normal lưu dưới dạng local-space direction
	# (vì basis của _parent ≈ basis của plane, to_local chỉ translate)
	var data                  := StrokeData.new()
	data.mesh_inst             = mi
	data.stamp_positions       = stamp_positions
	data.stamp_normals         = stamp_normals
	data.is_surface_normal     = _use_surface_normal
	data.rng_seed              = _rng.seed
	data.preset                = _preview_preset
	data.brush_size            = _preview_size
	data.thickness             = _preview_thickness
	data.opacity               = _preview_opacity
	data.spacing               = _preview_spacing
	data.color                 = current_color
	data.plane_right           = _world_normal_to_local(_plane_right)
	data.plane_up              = _world_normal_to_local(_plane_up)
	data.plane_normal          = _world_normal_to_local(_plane_normal)
	data.render_order          = _stroke_counter

	_points.clear()
	_preview_stamp_positions.clear()
	_preview_stamp_normals.clear()
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
	var mi      := MeshInstance3D.new()
	mi.mesh      = amesh
	mi.top_level = false
	mi.set_surface_override_material(0, _build_material(_preview_preset, _plane_normal))
	return mi

func cancel_stroke() -> void:
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null
	_points.clear()
	_preview_stamp_positions.clear()
	_preview_stamp_normals.clear()
	_preview_verts.clear()
	_preview_normals.clear()
	_preview_uvs.clear()
	_preview_colors.clear()

func is_drawing() -> bool:
	return not _points.is_empty()

# ── Eraser ────────────────────────────────────────────────────
# world_point: world space hit point từ raycast
func erase_at(world_point: Vector3, strokes: Array, radius: float) -> void:
	for data in strokes:
		var data_typed := data as StrokeData
		if data_typed == null or data_typed.stamp_positions.is_empty():
			continue
		if data_typed.mesh_inst == null:
			continue

		# Convert world hit point → local space của mesh parent
		var parent_node := data_typed.mesh_inst.get_parent() as Node3D
		var local_hit   := world_point
		if parent_node:
			local_hit = parent_node.to_local(world_point)

		var before_count := data_typed.stamp_positions.size()
		var kept_pos: Array[Vector3] = []
		var kept_nrm: Array[Vector3] = []
		var has_normals := data_typed.stamp_normals.size() == data_typed.stamp_positions.size()

		for i in range(data_typed.stamp_positions.size()):
			# stamp_positions đã là local space → compare trực tiếp
			if data_typed.stamp_positions[i].distance_to(local_hit) > radius:
				kept_pos.append(data_typed.stamp_positions[i])
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
			var mi := _build_mesh_from_stamps_local(
				kept_pos,
				kept_nrm if has_normals else [],
				data_typed.is_surface_normal,
				data_typed.preset,
				data_typed.rng_seed,
				data_typed.color,
				data_typed.brush_size,
				data_typed.thickness,
				data_typed.opacity
			)
			if mi:
				_set_render_priority(mi, data_typed.render_order)
				data_typed.mesh_inst = mi
				_parent.add_child(mi)

# ── Build mesh từ local-space stamp positions ─────────────────
func _build_mesh_from_stamps_local(
	stamp_positions:   Array,   # local space
	stamp_normals:     Array,   # local space
	is_surface_normal: bool,
	preset:            BrushPreset,
	rng_seed:          int,
	col_override:      Color  = Color(-1, 0, 0),
	size_override:     float  = -1.0,
	thick_override:    float  = -1.0,
	opacity_override:  float  = -1.0
) -> MeshInstance3D:
	if stamp_positions.is_empty():
		return null

	var base_color := col_override if col_override.r >= 0.0 else current_color
	var size       := size_override    if size_override    >= 0.0 else (preset.brush_size if preset else 0.08)
	var thickness  := thick_override   if thick_override   >= 0.0 else (preset.thickness  if preset else 0.5)
	var opacity    := opacity_override if opacity_override >= 0.0 else (preset.opacity    if preset else 1.0)
	var has_normals := is_surface_normal and stamp_normals.size() == stamp_positions.size()

	# Fallback normal: local Z (forward của stroke_container ≈ normal của plane)
	var fallback_normal := Vector3(0, 0, -1)

	var verts   := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var colors  := PackedColorArray()

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	for i in range(stamp_positions.size()):
		var pos_local := stamp_positions[i] as Vector3

		var pn: Vector3
		if has_normals:
			pn = (stamp_normals[i] as Vector3).normalized()
		else:
			pn = fallback_normal

		var ref_up := Vector3.UP if absf(pn.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var pr     := ref_up.cross(pn).normalized()
		var pu     := pn.cross(pr).normalized()

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
		var center := pos_local + scatter_offset

		var cos_a := cos(stamp_angle)
		var sin_a := sin(stamp_angle)
		var r     := (pr * cos_a + pu * sin_a).normalized()
		var u     := (pr * (-sin_a) + pu * cos_a).normalized()

		var col := Color(
			base_color.r, base_color.g, base_color.b,
			base_color.a * opacity * stamp_opacity
		)

		# --- Quad 1: Nằm ngang (trục r và u) ---
		var tl1 = center + u * half_w - r * half_w
		var tr1 = center + u * half_w + r * half_w
		var bl1 = center - u * half_w - r * half_w
		var br1 = center - u * half_w + r * half_w
		# Ở đây bạn đã bật vẽ cả mặt trên (pn) và mặt dưới (-pn) rồi, rất tốt
		_add_quad(verts, normals, uvs, colors, bl1, br1, tr1, tl1,  pn, col)
		_add_quad(verts, normals, uvs, colors, br1, bl1, tl1, tr1, -pn, col)
		
		var half_d = half_w * thickness
		
		# --- Quad 2: Dựng đứng (trục u và pn) ---
		var tl2 = center + u * half_w - pn * half_d
		var tr2 = center + u * half_w + pn * half_d
		var bl2 = center - u * half_w - pn * half_d
		var br2 = center - u * half_w + pn * half_d
		_add_quad_side(verts, normals, uvs, colors, bl2, br2, tr2, tl2,  r, col)
		_add_quad_side(verts, normals, uvs, colors, br2, bl2, tl2, tr2, -r, col)

		# --- Quad 3: Dựng đứng chéo (trục r và pn) ---
		# Bổ sung thêm Quad 3 vuông góc với 2 mặt trên
		var tl3 = center + r * half_w - pn * half_d
		var tr3 = center + r * half_w + pn * half_d
		var bl3 = center - r * half_w - pn * half_d
		var br3 = center - r * half_w + pn * half_d
		_add_quad_side(verts, normals, uvs, colors, bl3, br3, tr3, tl3,  u, col)
		_add_quad_side(verts, normals, uvs, colors, br3, bl3, tl3, tr3, -u, col)

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

	var mi      := MeshInstance3D.new()
	mi.mesh      = amesh
	mi.top_level = false
	mi.set_surface_override_material(0, _build_material(preset, _plane_normal))
	return mi

# ── Helper: add 1 quad ────────────────────────────────────────
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

# UV.y += 2.0 → shader nhận ra đây là mặt cạnh → fade theo góc nghiêng
func _add_quad_side(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	uvs:     PackedVector2Array,
	colors:  PackedColorArray,
	bl: Vector3, br: Vector3, tr: Vector3, tl: Vector3,
	normal: Vector3, col: Color
) -> void:
	verts.append(bl);  normals.append(normal); uvs.append(Vector2(0,3)); colors.append(col)
	verts.append(br);  normals.append(normal); uvs.append(Vector2(1,3)); colors.append(col)
	verts.append(tr);  normals.append(normal); uvs.append(Vector2(1,2)); colors.append(col)
	verts.append(bl);  normals.append(normal); uvs.append(Vector2(0,3)); colors.append(col)
	verts.append(tr);  normals.append(normal); uvs.append(Vector2(1,2)); colors.append(col)
	verts.append(tl);  normals.append(normal); uvs.append(Vector2(0,2)); colors.append(col)

func _set_render_priority(_mi: MeshInstance3D, _priority: int) -> void:
	# Deprecated: depth_offset và render_priority nay được quản lý tập trung
	# tại DrawingPlane._apply_depth_offset(). Giữ hàm này để tránh lỗi call site.
	pass

func _build_material(preset: BrushPreset, plane_normal: Vector3 = Vector3.ZERO) -> ShaderMaterial:
	var mat   := ShaderMaterial.new()
	mat.shader = _create_shader()
	if preset and preset.brush_texture != null:
		mat.set_shader_parameter("brush_tex",     preset.brush_texture)
		mat.set_shader_parameter("use_brush_tex", true)
	else:
		mat.set_shader_parameter("use_brush_tex", false)
	# Truyền normal của plane để shader push theo hướng cố định — không phụ thuộc face normal
	mat.set_shader_parameter("plane_normal", plane_normal)
	return mat

func _create_shader() -> Shader:
	var s  := Shader.new()
	s.code  = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D brush_tex : filter_linear_mipmap, repeat_disable, hint_default_white;
uniform bool use_brush_tex  = false;
uniform vec3 plane_normal   = vec3(0.0, 0.0, 1.0);
uniform float depth_offset      = 0.0;
uniform float offset_multiplier = 0.01;

void vertex() {
	 VERTEX += NORMAL * depth_offset * offset_multiplier;
}
void fragment() {
	bool is_side = UV.y >= 2.0;
	vec2 real_uv = is_side ? UV - vec2(0.0, 2.0) : UV;

	vec3 c =  COLOR.rgb;
	vec3 linear_color = mix(
		c / 12.92,
		pow((c + 0.055) / 1.055, vec3(2.4)),
		step(0.04045, c)
	);
	float tex_alpha = 1.0;
	if (use_brush_tex) {
		vec4  brush    = texture(brush_tex, real_uv);
		float lum      = dot(brush.rgb, vec3(0.299, 0.587, 0.114));
		tex_alpha = (1.0 - lum) * brush.a;
	}
	float alpha;
	if (is_side) {
	    float facing = abs(dot(NORMAL, VIEW));
	    // Chỉ hiện khi nhìn gần như đối diện hoàn toàn
	    if (facing < 0.95) discard;
	    float side_fade = smoothstep(0.9, 1.0, facing);
	    alpha = COLOR.a * side_fade * tex_alpha;
	} else {
		alpha = COLOR.a * tex_alpha;
	}
	ALBEDO = linear_color;
	ALPHA  = clamp(COLOR.a * tex_alpha, 0.0, 1.0);
}
"""
	return s
