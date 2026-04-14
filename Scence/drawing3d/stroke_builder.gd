# stroke_builder.gd
class_name StrokeBuilder
extends Node

# ── StrokeData ───────────────────────────────────────────────────
class StrokeData:
	var mesh_inst:   MeshInstance3D          = null
	# Path points và normals lưu trong LOCAL SPACE của stroke_container
	var points:      Array[Vector3]          = []
	var normals:     Array[Vector3]          = []   # per-point surface normal (local)
	var stroke_type: BrushPreset.StrokeType  = BrushPreset.StrokeType.LINE
	var shape_type:  BrushPreset.ShapeType   = BrushPreset.ShapeType.SQUARE
	var size:        float                   = 0.1   # world unit
	var height:      float                   = 0.1   # world unit (RECTANGLE only)
	var thickness:   float                   = 0.05  # world unit
	var opacity:     float                   = 1.0
	var color:       Color                   = Color.BLACK
	var render_order: int                    = 0
	# Jitter seeds (SHAPE only) — lưu để rebuild sau erase
	var rng_seed:    int                     = 0

# ── Exports / public state ───────────────────────────────────────
@export var brushes:           Array[BrushPreset] = []
var current_brush_index:       int                = 0
var current_color:             Color              = Color.BLACK

# ── Internal refs ────────────────────────────────────────────────
var _camera:  Camera3D    = null
var _plane:   DrawingPlane = null
var _parent:  Node3D      = null   # stroke_container

var _plane_normal: Vector3 = Vector3.ZERO
var _plane_right:  Vector3 = Vector3.ZERO
var _plane_up:     Vector3 = Vector3.ZERO
var _use_surface_normal: bool = false

# ── Live stroke state ────────────────────────────────────────────
var _points:        Array[Vector3] = []
var _normals:       Array[Vector3] = []   # per-point, world space khi vẽ
var _rng:           RandomNumberGenerator = RandomNumberGenerator.new()

var _preview_inst:  MeshInstance3D = null
var _preview_preset: BrushPreset   = null

# Incremental preview buffers — chỉ dùng cho LINE stroke
# Tránh rebuild toàn bộ mesh mỗi frame khi add_point
var _prev_verts:   PackedVector3Array = PackedVector3Array()
var _prev_normals: PackedVector3Array = PackedVector3Array()
var _prev_colors:  PackedColorArray   = PackedColorArray()
var _prev_rings:        Array         = []  # ring verts tại mỗi điểm đã commit
var _prev_ring_normals: Array         = []  # outward normals tương ứng
var _prev_tangents:     Array[Vector3] = []
var _prev_frame_n:      Array[Vector3] = []
var _prev_frame_b:      Array[Vector3] = []

# Shape drag-size mode (Alt + drag)
var _drag_size_active: bool    = false
var _drag_start_local: Vector3 = Vector3.ZERO  # local space corner 1
var _drag_end_local:   Vector3 = Vector3.ZERO  # local space corner 2

const MIN_DIST     := 0.001
const SIDES        := 6   # số cạnh cross-section của LINE tube
const CYLINDER_SEGS := 8  # số cạnh cross-section của CIRCLE shape

# ── Setup ────────────────────────────────────────────────────────
func setup(camera: Camera3D, parent: Node3D, plane: DrawingPlane = null) -> void:
	_camera = camera
	_parent = parent
	_plane  = plane
	if plane != null:
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
	if brushes.is_empty(): return null
	return brushes[clamp(current_brush_index, 0, brushes.size() - 1)]

# ── World ↔ local helpers ────────────────────────────────────────
func _to_local(world_pos: Vector3) -> Vector3:
	return _parent.to_local(world_pos) if _parent else world_pos

func _world_normal_to_local(n: Vector3) -> Vector3:
	return (_parent.global_basis.inverse() * n) if _parent else n

func _resolve_point_normal(hit_normal_world: Vector3) -> Vector3:
	# Trả về world-space normal tại điểm hit
	if _use_surface_normal and hit_normal_world != Vector3.ZERO:
		return hit_normal_world.normalized()
	return _plane_normal

# ════════════════════════════════════════════════════════════════
#  STROKE START / ADD / FINISH
# ════════════════════════════════════════════════════════════════

func start_stroke(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	_points.clear()
	_normals.clear()
	_drag_size_active = false
	_rng.randomize()
	_preview_preset = get_current_preset()

	# Reset incremental buffers
	_prev_verts.clear(); _prev_normals.clear(); _prev_colors.clear()
	_prev_rings.clear(); _prev_ring_normals.clear()
	_prev_tangents.clear(); _prev_frame_n.clear(); _prev_frame_b.clear()

	if _preview_inst != null:
		_preview_inst.queue_free()
	_preview_inst           = MeshInstance3D.new()
	_preview_inst.top_level = false
	_parent.add_child(_preview_inst)

	var world_n := _resolve_point_normal(hit_normal)
	_points.append(_to_local(world_point))
	_normals.append(_world_normal_to_local(world_n))
	# 1 điểm chưa đủ vẽ tube — đợi add_point đầu tiên

func add_point(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	if _points.is_empty() or _drag_size_active:
		return
	var local_pt := _to_local(world_point)
	if local_pt.distance_to(_points.back()) < MIN_DIST:
		return
	var world_n := _resolve_point_normal(hit_normal)
	_points.append(local_pt)
	_normals.append(_world_normal_to_local(world_n))
	_flush_preview()

func finish_stroke() -> StrokeData:
	if _points.is_empty():
		_cleanup_preview()
		return null

	var preset := _preview_preset if _preview_preset else get_current_preset()
	if preset == null:
		_cleanup_preview()
		return null

	var mi := _build_mesh(_points, _normals, preset, _rng.seed)
	_cleanup_preview()

	if mi == null:
		return null

	var data            := StrokeData.new()
	data.mesh_inst       = mi
	data.points          = _points.duplicate()
	data.normals         = _normals.duplicate()
	data.stroke_type     = preset.stroke_type
	data.shape_type      = preset.shape_type
	data.size            = preset.size_u()
	data.height          = preset.height_u()
	data.thickness       = preset.thickness_u()
	data.opacity         = preset.opacity
	data.color           = current_color
	data.rng_seed        = _rng.seed
	_points.clear()
	_normals.clear()
	return data

# ── Drag-size mode (Alt + drag) ──────────────────────────────────
# Click = điểm bắt đầu, kéo = kéo dài stroke theo hướng kéo.
# Chiều rộng/radius luôn từ preset — không thay đổi.
func start_drag_size(world_point: Vector3, hit_normal: Vector3 = Vector3.ZERO) -> void:
	_points.clear()
	_normals.clear()
	_drag_size_active = true
	_drag_start_local = _to_local(world_point)
	_drag_end_local   = _drag_start_local
	_rng.randomize()
	_preview_preset   = get_current_preset()

	if _preview_inst != null: _preview_inst.queue_free()
	_preview_inst           = MeshInstance3D.new()
	_preview_inst.top_level = false
	_parent.add_child(_preview_inst)

	var world_n := _resolve_point_normal(hit_normal)
	_normals.append(_world_normal_to_local(world_n))

func update_drag_size(world_point: Vector3) -> void:
	if not _drag_size_active: return
	_drag_end_local = _to_local(world_point)
	_flush_drag_size_preview()

func finish_drag_size() -> StrokeData:
	if not _drag_size_active:
		_cleanup_preview()
		return null
	_drag_size_active = false

	var preset := _preview_preset if _preview_preset else get_current_preset()
	if preset == null:
		_cleanup_preview()
		return null

	var pn_local  := _world_normal_to_local(_plane_normal).normalized()
	var delta     := _drag_end_local - _drag_start_local
	var fwd_local := delta - delta.dot(pn_local) * pn_local
	if fwd_local.length() < MIN_DIST:
		_cleanup_preview()
		return null

	var nrm  := _normals[0] if not _normals.is_empty() else pn_local
	var pts:  Array[Vector3] = [_drag_start_local, _drag_end_local]
	var nrms: Array[Vector3] = [nrm, nrm]

	var mi := _build_mesh(pts, nrms, preset, _rng.seed)
	_cleanup_preview()
	if mi == null: return null

	var data         := StrokeData.new()
	data.mesh_inst    = mi
	data.points       = pts
	data.normals      = nrms
	data.stroke_type  = preset.stroke_type
	data.shape_type   = preset.shape_type
	data.size         = preset.size_u()
	data.height       = preset.height_u()
	data.thickness    = preset.thickness_u()
	data.opacity      = preset.opacity
	data.color        = current_color
	data.rng_seed     = _rng.seed
	return data


# ── Preview flush ────────────────────────────────────────────────
# LINE: incremental — chỉ tính thêm segment mới nhất
# SHAPE: rebuild toàn bộ (stamp count nhỏ, chấp nhận được)
func _flush_preview() -> void:
	if _preview_inst == null or _points.size() < 2: return
	var preset := _preview_preset if _preview_preset else get_current_preset()
	if preset == null: return

	var priority := clampi(_plane._strokes.size() if _plane else 0, -127, 127)

	if preset.stroke_type == BrushPreset.StrokeType.LINE:
		_flush_line_incremental(preset, priority)
	else:
		# SHAPE: rebuild bình thường
		var mi := _build_mesh(_points, _normals, preset, _rng.seed)
		if mi == null: return
		var mat := mi.get_surface_override_material(0) as ShaderMaterial
		if mat:
			mat.render_priority = priority
			mat.set_shader_parameter("depth_offset", -float(priority) * 0.01 - 0.05)
		_preview_inst.mesh = mi.mesh
		_preview_inst.set_surface_override_material(0, mat if mat else mi.get_surface_override_material(0))
		mi.queue_free()

func _flush_line_incremental(preset: BrushPreset, priority: int) -> void:
	# Lần đầu (mới 2 điểm) hoặc sau khi erase: build từ đầu
	var n_pts := _points.size()
	if _prev_rings.size() != n_pts - 1:
		# Rebuild hoàn toàn rồi cache lại
		_prev_verts.clear(); _prev_normals.clear(); _prev_colors.clear()
		_prev_rings.clear(); _prev_ring_normals.clear()
		_prev_tangents.clear(); _prev_frame_n.clear(); _prev_frame_b.clear()
		_build_line_incremental_full(preset)
	else:
		# Chỉ append segment cuối
		_build_line_incremental_append(preset)

	# Upload mesh
	if _prev_verts.is_empty(): return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _prev_verts
	arrays[Mesh.ARRAY_NORMAL] = _prev_normals
	arrays[Mesh.ARRAY_COLOR]  = _prev_colors
	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_preview_inst.mesh = amesh
	var mat := _build_material()
	mat.render_priority = priority
	mat.set_shader_parameter("depth_offset", -float(priority) * 0.01 - 0.05)
	_preview_inst.set_surface_override_material(0, mat)

func _build_line_incremental_full(preset: BrushPreset) -> void:
	# Tính toàn bộ từ đầu và cache rings, frame, verts
	var radius := preset.size_u() * 0.5
	var col    := Color(current_color.r, current_color.g, current_color.b,
						current_color.a * preset.opacity)
	var n_pts  := _points.size()

	# Tangents
	for i in range(n_pts):
		var t: Vector3
		if i == 0:
			t = (_points[1] - _points[0]).normalized()
		elif i == n_pts - 1:
			t = (_points[i] - _points[i-1]).normalized()
		else:
			var ta := (_points[i]   - _points[i-1]).normalized()
			var tb := (_points[i+1] - _points[i]).normalized()
			t = (ta + tb).normalized()
			if t.length() < 0.001: t = ta
		_prev_tangents.append(t)

	# Frame seed
	var n0 := _normals[0].normalized() if not _normals.is_empty() else _plane_normal.normalized()
	n0 = (n0 - _prev_tangents[0] * _prev_tangents[0].dot(n0)).normalized()
	if n0.length() < 0.001:
		n0 = Vector3.UP if absf(_prev_tangents[0].dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	_prev_frame_n.append(n0)
	_prev_frame_b.append(_prev_tangents[0].cross(n0).normalized())

	# Transport
	for i in range(1, n_pts):
		var t_prev := _prev_tangents[i-1]; var t_curr := _prev_tangents[i]
		var n_prev := _prev_frame_n[i-1]
		var axis := t_prev.cross(t_curr); var angle := t_prev.angle_to(t_curr)
		var n_curr := n_prev.rotated(axis.normalized(), angle) 			if axis.length() > 0.0001 and absf(angle) > 0.0001 else n_prev
		n_curr = (n_curr - t_curr * t_curr.dot(n_curr)).normalized()
		if n_curr.length() < 0.001: n_curr = n_prev
		_prev_frame_n.append(n_curr)
		_prev_frame_b.append(t_curr.cross(n_curr).normalized())

	# Rings
	for i in range(n_pts):
		var ring: Array[Vector3] = []; var rnrm: Array[Vector3] = []
		for j in range(SIDES):
			var a := TAU * float(j) / float(SIDES)
			var out_n := _prev_frame_n[i] * cos(a) + _prev_frame_b[i] * sin(a)
			ring.append(_points[i] + out_n * radius); rnrm.append(out_n)
		_prev_rings.append(ring); _prev_ring_normals.append(rnrm)

	# Build tất cả segments
	for i in range(n_pts - 1):
		_append_tube_segment(i, col)

	# Caps
	_append_caps(col, radius)

func _build_line_incremental_append(preset: BrushPreset) -> void:
	if _points.size() < 2: return
	
	var radius := preset.size_u() * 0.5
	var col := Color(current_color.r, current_color.g, current_color.b,
					 current_color.a * preset.opacity)
	var i := _points.size() - 1  # điểm mới nhất
	
	# 1. Cập nhật tangent & frame (giữ nguyên như cũ)
	var ta := (_points[i-1] - _points[i-2]).normalized() if i >= 2 else (_points[1] - _points[0]).normalized()
	var tb := (_points[i] - _points[i-1]).normalized()
	var t_mid := (ta + tb).normalized()
	if t_mid.length() < 0.001: t_mid = tb
	_prev_tangents[i-1] = t_mid
	_prev_tangents.append(tb)
	
	# Transport frame (giữ nguyên)
	var t_prev := _prev_tangents[i-1]
	var t_curr := _prev_tangents[i]
	var n_prev := _prev_frame_n[i-1]
	var axis := t_prev.cross(t_curr)
	var angle := t_prev.angle_to(t_curr)
	var n_curr := n_prev.rotated(axis.normalized(), angle) if axis.length() > 0.0001 and absf(angle) > 0.0001 else n_prev
	n_curr = (n_curr - t_curr * t_curr.dot(n_curr)).normalized()
	if n_curr.length() < 0.001: n_curr = n_prev
	_prev_frame_n.append(n_curr)
	_prev_frame_b.append(t_curr.cross(n_curr).normalized())
	
	# 2. Tạo ring mới
	var ring: Array[Vector3] = []
	var rnrm: Array[Vector3] = []
	for j in range(SIDES):
		var a := TAU * float(j) / float(SIDES)
		var out_n := n_curr * cos(a) + _prev_frame_b[i] * sin(a)
		ring.append(_points[i] + out_n * radius)
		rnrm.append(out_n)
	_prev_rings.append(ring)
	_prev_ring_normals.append(rnrm)
	
	# 3. XÓA CHỈ END CAP CŨ (không động đến start cap)
	var verts_per_cap := SIDES * 3
	_prev_verts.resize(_prev_verts.size() - verts_per_cap)      # xóa end cap cũ
	_prev_normals.resize(_prev_normals.size() - verts_per_cap)
	_prev_colors.resize(_prev_colors.size() - verts_per_cap)
	
	# 4. Thêm segment mới + CHỈ end cap mới
	_append_tube_segment(i - 1, col)
	_append_end_cap_only(col, radius)   # ← hàm mới, chỉ thêm end cap

func _append_end_cap_only(col: Color, radius: float) -> void:
	var n_pts := _points.size()
	var t_e := _prev_tangents[n_pts - 1]
	for j in range(SIDES):
		var j1 := (j + 1) % SIDES
		_prev_verts.append(_points[n_pts-1]); _prev_normals.append(t_e); _prev_colors.append(col)
		_prev_verts.append(_prev_rings[n_pts-1][j]); _prev_normals.append(t_e); _prev_colors.append(col)
		_prev_verts.append(_prev_rings[n_pts-1][j1]); _prev_normals.append(t_e); _prev_colors.append(col)

func _append_tube_segment(i: int, col: Color) -> void:
	for j in range(SIDES):
		var j1 := (j + 1) % SIDES
		var a: Vector3 = _prev_rings[i][j];   var b: Vector3 = _prev_rings[i][j1]
		var c: Vector3 = _prev_rings[i+1][j]; var d: Vector3 = _prev_rings[i+1][j1]
		var na: Vector3 = _prev_ring_normals[i][j];   var nb: Vector3 = _prev_ring_normals[i][j1]
		var nc: Vector3 = _prev_ring_normals[i+1][j]; var nd: Vector3 = _prev_ring_normals[i+1][j1]
		_prev_verts.append(a); _prev_normals.append(na); _prev_colors.append(col)
		_prev_verts.append(b); _prev_normals.append(nb); _prev_colors.append(col)
		_prev_verts.append(d); _prev_normals.append(nd); _prev_colors.append(col)
		_prev_verts.append(a); _prev_normals.append(na); _prev_colors.append(col)
		_prev_verts.append(d); _prev_normals.append(nd); _prev_colors.append(col)
		_prev_verts.append(c); _prev_normals.append(nc); _prev_colors.append(col)

func _append_caps(col: Color, radius: float) -> void:
	var n_pts := _points.size()
	# Start cap
	var t_s := _prev_tangents[0]
	for j in range(SIDES):
		var j1 := (j + 1) % SIDES
		_prev_verts.append(_points[0]);            _prev_normals.append(-t_s); _prev_colors.append(col)
		_prev_verts.append(_prev_rings[0][j1]);    _prev_normals.append(-t_s); _prev_colors.append(col)
		_prev_verts.append(_prev_rings[0][j]);     _prev_normals.append(-t_s); _prev_colors.append(col)
	# End cap
	var t_e := _prev_tangents[n_pts - 1]
	for j in range(SIDES):
		var j1 := (j + 1) % SIDES
		_prev_verts.append(_points[n_pts-1]);           _prev_normals.append(t_e); _prev_colors.append(col)
		_prev_verts.append(_prev_rings[n_pts-1][j]);    _prev_normals.append(t_e); _prev_colors.append(col)
		_prev_verts.append(_prev_rings[n_pts-1][j1]);   _prev_normals.append(t_e); _prev_colors.append(col)

func _flush_drag_size_preview() -> void:
	if _preview_inst == null: return
	var preset := _preview_preset if _preview_preset else get_current_preset()
	if preset == null: return

	var pn_local  := _world_normal_to_local(_plane_normal).normalized()
	var delta     := _drag_end_local - _drag_start_local
	var fwd_local := delta - delta.dot(pn_local) * pn_local
	if fwd_local.length() < MIN_DIST: return   # chưa kéo đủ xa

	var nrm  := _normals[0] if not _normals.is_empty() else pn_local
	var pts:  Array[Vector3] = [_drag_start_local, _drag_end_local]
	var nrms: Array[Vector3] = [nrm, nrm]

	var mi := _build_mesh(pts, nrms, preset, _rng.seed)
	if mi == null: return

	# Render priority: luôn trên tất cả stroke đã vẽ
	var priority := clampi((_plane._strokes.size() if _plane else 0), -127, 127)
	var mat := mi.get_surface_override_material(0) as ShaderMaterial
	if mat:
		mat.render_priority = priority
		mat.set_shader_parameter("depth_offset", -float(priority) * 0.01 - 0.05)
	_preview_inst.mesh = mi.mesh
	_preview_inst.set_surface_override_material(0, mat if mat else mi.get_surface_override_material(0))
	mi.queue_free()

func _cleanup_preview() -> void:
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null

# ════════════════════════════════════════════════════════════════
#  MESH BUILDERS
# ════════════════════════════════════════════════════════════════

func _build_mesh(
	pts:    Array[Vector3],
	nrms:   Array[Vector3],
	preset: BrushPreset,
	seed:   int
) -> MeshInstance3D:
	if pts.is_empty(): return null
	match preset.stroke_type:
		BrushPreset.StrokeType.LINE:
			return _build_line_mesh(pts, nrms, preset)
		BrushPreset.StrokeType.SHAPE:
			return _build_shape_mesh(pts, nrms, preset, seed)
	return null

# ── LINE: polygon tube liền mạch dọc path ───────────────────────
# Parallel Transport Frame (giống code cũ) — không twist, không lag.
# SIDES cạnh cross-section, radius = size/2. Không dùng thickness.

func _build_line_mesh(
	pts:    Array[Vector3],
	nrms:   Array[Vector3],
	preset: BrushPreset
) -> MeshInstance3D:
	if pts.size() < 2: return null

	var radius := preset.size_u() * 0.5
	var col    := Color(current_color.r, current_color.g, current_color.b,
						current_color.a * preset.opacity)

	var verts:   PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors:  PackedColorArray   = PackedColorArray()

	var n_pts := pts.size()

	# ── Bước 1: tangent tại mỗi điểm (average của 2 segment liền kề) ──
	var tangents: Array[Vector3] = []
	for i in range(n_pts):
		var t: Vector3
		if i == 0:
			t = (pts[1] - pts[0]).normalized()
		elif i == n_pts - 1:
			t = (pts[i] - pts[i-1]).normalized()
		else:
			var ta := (pts[i]   - pts[i-1]).normalized()
			var tb := (pts[i+1] - pts[i]).normalized()
			t       = (ta + tb).normalized()
			if t.length() < 0.001: t = ta
		tangents.append(t)

	# ── Bước 2: Parallel Transport Frame ─────────────────────────────
	# normal[0] lấy từ plane normal tại điểm đó (nếu có) hoặc từ cam
	var frame_n: Array[Vector3] = []
	var frame_b: Array[Vector3] = []

	var n0: Vector3
	if not nrms.is_empty():
		# Dùng plane normal làm seed → nét vẽ nổi lên khỏi plane
		n0 = nrms[0].normalized()
		# Project ra khỏi tangent để đảm bảo vuông góc
		n0 = (n0 - tangents[0] * tangents[0].dot(n0)).normalized()
	if n0.length() < 0.001:
		n0 = _plane_normal.normalized()
		n0 = (n0 - tangents[0] * tangents[0].dot(n0)).normalized()
	if n0.length() < 0.001:
		n0 = Vector3.UP if absf(tangents[0].dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	frame_n.append(n0)
	frame_b.append(tangents[0].cross(n0).normalized())

	for i in range(1, n_pts):
		var t_prev := tangents[i - 1]
		var t_curr := tangents[i]
		var n_prev := frame_n[i - 1]

		var axis  := t_prev.cross(t_curr)
		var angle := t_prev.angle_to(t_curr)
		var n_curr: Vector3
		if axis.length() < 0.0001 or absf(angle) < 0.0001:
			n_curr = n_prev
		else:
			n_curr = n_prev.rotated(axis.normalized(), angle)

		# Re-orthogonalize
		n_curr = (n_curr - t_curr * t_curr.dot(n_curr)).normalized()
		if n_curr.length() < 0.001:
			n_curr = frame_n[i - 1]
		frame_n.append(n_curr)
		frame_b.append(t_curr.cross(n_curr).normalized())

	# ── Bước 3: build rings ───────────────────────────────────────────
	var rings: Array = []
	var ring_normals: Array = []   # outward normals tương ứng
	for i in range(n_pts):
		var ring:  Array[Vector3] = []
		var rnrms: Array[Vector3] = []
		for j in range(SIDES):
			var angle  := TAU * float(j) / float(SIDES)
			var out_n  := frame_n[i] * cos(angle) + frame_b[i] * sin(angle)
			ring.append(pts[i] + out_n * radius)
			rnrms.append(out_n)
		rings.append(ring)
		ring_normals.append(rnrms)

	# ── Bước 4: nối rings thành tube ─────────────────────────────────
	for i in range(n_pts - 1):
		for j in range(SIDES):
			var j1 := (j + 1) % SIDES
			var a  : Vector3 = rings[i][j];   var b : Vector3 = rings[i][j1]
			var c  : Vector3 = rings[i+1][j]; var d : Vector3 = rings[i+1][j1]
			var na : Vector3 = ring_normals[i][j]
			var nb : Vector3 = ring_normals[i][j1]
			var nc : Vector3 = ring_normals[i+1][j]
			var nd : Vector3 = ring_normals[i+1][j1]
			# Tri 1: a, b, d
			verts.append(a); normals.append(na); colors.append(col)
			verts.append(b); normals.append(nb); colors.append(col)
			verts.append(d); normals.append(nd); colors.append(col)
			# Tri 2: a, d, c
			verts.append(a); normals.append(na); colors.append(col)
			verts.append(d); normals.append(nd); colors.append(col)
			verts.append(c); normals.append(nc); colors.append(col)

	# ── Bước 5: caps (fan triangles) ─────────────────────────────────
	var t_start := tangents[0]
	var t_end   := tangents[n_pts - 1]
	# Start cap
	for j in range(SIDES):
		var j1 := (j + 1) % SIDES
		verts.append(pts[0]);         normals.append(-t_start); colors.append(col)
		verts.append(rings[0][j1]);   normals.append(-t_start); colors.append(col)
		verts.append(rings[0][j]);    normals.append(-t_start); colors.append(col)
	# End cap
	for j in range(SIDES):
		var j1 := (j + 1) % SIDES
		verts.append(pts[n_pts-1]);          normals.append(t_end); colors.append(col)
		verts.append(rings[n_pts-1][j]);     normals.append(t_end); colors.append(col)
		verts.append(rings[n_pts-1][j1]);    normals.append(t_end); colors.append(col)

	return _make_mesh_inst(verts, normals, colors, preset)

# ── SHAPE: stamp nhiều hình dọc path ────────────────────────────
# ── SHAPE: extrude cross-section dọc path ───────────────────────
# SQUARE/RECTANGLE → tiết diện chữ nhật (size × height), extrude dọc path
# CIRCLE           → tiết diện tròn (radius = size/2), extrude dọc path
# Dùng cùng Parallel Transport Frame như LINE — 1 mesh duy nhất, không stamp.
# thickness = chiều dài extrude theo plane normal (nổi lên khỏi plane).
func _build_shape_mesh(
	pts:    Array[Vector3],
	nrms:   Array[Vector3],
	preset: BrushPreset,
	_seed:  int
) -> MeshInstance3D:
	if pts.size() < 2: return null

	var col := Color(current_color.r, current_color.g, current_color.b,
					 current_color.a * preset.opacity)

	match preset.shape_type:
		BrushPreset.ShapeType.SQUARE:
			return _extrude_rect_path(pts, nrms, preset.size_u(), preset.size_u(),
									  preset.thickness_u(), col, preset)
		BrushPreset.ShapeType.RECTANGLE:
			return _extrude_rect_path(pts, nrms, preset.size_u(), preset.height_u(),
									  preset.thickness_u(), col, preset)
		BrushPreset.ShapeType.CIRCLE:
			return _extrude_circle_path(pts, nrms, preset.size_u() * 0.5,
										preset.thickness_u(), col, preset)
	return null

# drag-size mode: 1 shape tĩnh tại center với size override
func _build_single_shape(
	pos_local: Vector3,
	pn_local:  Vector3,
	fwd_local: Vector3,
	preset:    BrushPreset,
	w:         float,
	h:         float,
	_seed:     int
) -> MeshInstance3D:
	# Tạo 2 điểm giả: pos ± fwd*epsilon để extrude có chiều dài tối thiểu
	var up    := pn_local.normalized()
	var right := fwd_local.cross(up).normalized()
	if right.length() < 0.001:
		right = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var eps   := maxf(w, h) * 0.5
	var pts:  Array[Vector3] = [pos_local - fwd_local * eps, pos_local + fwd_local * eps]
	var nrms: Array[Vector3] = [pn_local, pn_local]
	var col   := Color(current_color.r, current_color.g, current_color.b,
					   current_color.a * preset.opacity)
	match preset.shape_type:
		BrushPreset.ShapeType.SQUARE:
			var s := minf(w, h)
			return _extrude_rect_path(pts, nrms, s, s, preset.thickness_u(), col, preset)
		BrushPreset.ShapeType.RECTANGLE:
			return _extrude_rect_path(pts, nrms, w, h, preset.thickness_u(), col, preset)
		BrushPreset.ShapeType.CIRCLE:
			return _extrude_circle_path(pts, nrms, minf(w,h)*0.5, preset.thickness_u(), col, preset)
	return null

# ── Extrude rect cross-section ───────────────────────────────────
# Cross-section: chữ nhật half_w × half_t trong mặt (right, up)
# right = trục ngang trong plane, up = plane normal (thickness direction)
# fwd  = hướng di chuyển (Parallel Transport)
func _extrude_rect_path(
	pts:   Array[Vector3], nrms: Array[Vector3],
	w:     float, h: float, thick: float,
	col:   Color, preset: BrushPreset
) -> MeshInstance3D:
	var half_w := w     * 0.5
	var half_h := h     * 0.5   # chiều theo fwd (h = height của rect trong plane)
	var half_t := thick * 0.5   # chiều nổi lên (thickness)

	var verts:   PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors:  PackedColorArray   = PackedColorArray()

	# Tiết diện chữ nhật: 4 điểm trong mặt phẳng (right × up_sect)
	# right   = trục ngang (chiều w)
	# up_sect = plane normal (chiều thick)
	# Thứ tự: BL, BR, TR, TL  (B=−up_sect, T=+up_sect, L=−right, R=+right)
	var _rect_ring = func(center: Vector3, right: Vector3, up_sect: Vector3) -> Array:
		return [
			center - right * half_w - up_sect * half_t,  # BL
			center + right * half_w - up_sect * half_t,  # BR
			center + right * half_w + up_sect * half_t,  # TR
			center - right * half_w + up_sect * half_t,  # TL
		]

	var _quad2 = func(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
		for v in [a, b, c, a, c, d]:
			verts.append(v); normals.append(n); colors.append(col)
		for v in [a, d, c, a, c, b]:
			verts.append(v); normals.append(-n); colors.append(col)

	# Parallel Transport Frame — right là trục ngang, up_sect là plane normal
	var frames := _compute_ptf(pts, nrms)  # frames[i] = [right_i, up_sect_i]
	var n_pts  := pts.size()

	var rings: Array = []
	for i in range(n_pts):
		rings.append(_rect_ring.call(pts[i], frames[i][0], frames[i][1]))

	# Start cap (2 tri face)
	var fwd_s := (pts[1] - pts[0]).normalized()
	var r0: Array = rings[0]
	_quad2.call(r0[3], r0[2], r0[1], r0[0], -fwd_s)

	# Side faces: 4 mặt × (n_pts-1) segment
	for i in range(n_pts - 1):
		var ra: Array = rings[i]; var rb: Array = rings[i+1]
		var ua: Vector3 = frames[i][1]; var ub: Vector3 = frames[i+1][1]
		var ra_r: Vector3 = frames[i][0]; var rb_r: Vector3 = frames[i+1][0]
		# top (+up_sect)
		_quad2.call(ra[3], rb[3], rb[2], ra[2],  (ua+ub).normalized())
		# bottom (−up_sect)
		_quad2.call(ra[1], rb[1], rb[0], ra[0], -(ua+ub).normalized())
		# right (+right)
		_quad2.call(ra[2], rb[2], rb[1], ra[1],  (ra_r+rb_r).normalized())
		# left (−right)
		_quad2.call(ra[0], rb[0], rb[3], ra[3], -(ra_r+rb_r).normalized())

	# End cap
	var fwd_e := (pts[n_pts-1] - pts[n_pts-2]).normalized()
	var rn: Array = rings[n_pts-1]
	_quad2.call(rn[0], rn[1], rn[2], rn[3], fwd_e)

	return _make_mesh_inst(verts, normals, colors, preset)

# ── Extrude circle cross-section ─────────────────────────────────
func _extrude_circle_path(
	pts:    Array[Vector3], nrms: Array[Vector3],
	radius: float, thick: float,
	col:    Color, preset: BrushPreset
) -> MeshInstance3D:
	# thick = chiều nổi lên — scale trục up_sect của ellipse
	# Tức là cross-section là ellipse: trục ngang = radius, trục dọc = thick/2
	var half_t := thick * 0.5

	var verts:   PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors:  PackedColorArray   = PackedColorArray()

	var _quad2 = func(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
		for v in [a, b, c, a, c, d]:
			verts.append(v); normals.append(n); colors.append(col)
		for v in [a, d, c, a, c, b]:
			verts.append(v); normals.append(-n); colors.append(col)

	var frames := _compute_ptf(pts, nrms)
	var n_pts  := pts.size()

	# Ring tròn (ellipse nếu thick ≠ size)
	var _circle_ring = func(center: Vector3, right: Vector3, up_sect: Vector3) -> Array:
		var ring: Array = []
		for k in range(CYLINDER_SEGS):
			var a := TAU * float(k) / float(CYLINDER_SEGS)
			ring.append(center + right * cos(a) * radius + up_sect * sin(a) * half_t)
		return ring

	var rings: Array = []
	for i in range(n_pts):
		rings.append(_circle_ring.call(pts[i], frames[i][0], frames[i][1]))

	# ── Helper: build 1 hemi-ellipsoid cap ──────────────────────
	# Khớp với cross-section ellipse (radius × half_t) của tube body.
	# fwd_dir: +1 = end cap (hướng ra ngoài), -1 = start cap (hướng vào trong)
	const HEMI_LAT := 4
	var _hemi_cap = func(
		origin: Vector3, right: Vector3, up_sect: Vector3, fwd_dir: Vector3
	) -> void:
		for lat in range(HEMI_LAT):
			var a0 := PI * 0.5 * float(lat)     / float(HEMI_LAT)
			var a1 := PI * 0.5 * float(lat + 1) / float(HEMI_LAT)
			# cos(a) = scale của ring, sin(a) = tiến ra ngoài theo fwd
			var cr0 := cos(a0); var cs0 := sin(a0)
			var cr1 := cos(a1); var cs1 := sin(a1)
			for k in range(CYLINDER_SEGS):
				var b0 := TAU * float(k)     / float(CYLINDER_SEGS)
				var b1 := TAU * float(k + 1) / float(CYLINDER_SEGS)
				# Vị trí trên bề mặt ellipsoid (right*radius, up*half_t, fwd*radius)
				var v00 := origin + right * cos(b0) * radius * cr0 + up_sect * sin(b0) * half_t * cr0 + fwd_dir * radius * cs0
				var v10 := origin + right * cos(b1) * radius * cr0 + up_sect * sin(b1) * half_t * cr0 + fwd_dir * radius * cs0
				var v01 := origin + right * cos(b0) * radius * cr1 + up_sect * sin(b0) * half_t * cr1 + fwd_dir * radius * cs1
				var v11 := origin + right * cos(b1) * radius * cr1 + up_sect * sin(b1) * half_t * cr1 + fwd_dir * radius * cs1
				# Normal hướng ra ngoài (approximate từ vị trí)
				var n00 := (v00 - origin).normalized(); var n10 := (v10 - origin).normalized()
				var n01 := (v01 - origin).normalized(); var n11 := (v11 - origin).normalized()
				# Winding: ngược chiều cho start (fwd_dir âm) để normal hướng ra
				if fwd_dir.dot(fwd_dir) > 0 and (v00 - origin).dot(fwd_dir) >= 0:
					verts.append(v00); normals.append(n00); colors.append(col)
					verts.append(v10); normals.append(n10); colors.append(col)
					verts.append(v11); normals.append(n11); colors.append(col)
					verts.append(v00); normals.append(n00); colors.append(col)
					verts.append(v11); normals.append(n11); colors.append(col)
					verts.append(v01); normals.append(n01); colors.append(col)
				else:
					verts.append(v00); normals.append(n00); colors.append(col)
					verts.append(v11); normals.append(n11); colors.append(col)
					verts.append(v10); normals.append(n10); colors.append(col)
					verts.append(v00); normals.append(n00); colors.append(col)
					verts.append(v01); normals.append(n01); colors.append(col)
					verts.append(v11); normals.append(n11); colors.append(col)

	# Start cap hemisphere
	var fwd_s := (pts[1] - pts[0]).normalized()
	_hemi_cap.call(pts[0], frames[0][0], frames[0][1], -fwd_s)

	# ── Side quads ───────────────────────────────────────────────
	for i in range(n_pts - 1):
		var ra: Array = rings[i]; var rb: Array = rings[i+1]
		var cp_a := pts[i]; var cp_b := pts[i+1]
		for k in range(CYLINDER_SEGS):
			var k1 := (k+1) % CYLINDER_SEGS
			var a = ra[k]; var b = ra[k1]; var c = rb[k1]; var d = rb[k]
			var n_avg = ((a-cp_a)+(b-cp_a)+(c-cp_b)+(d-cp_b)).normalized()
			_quad2.call(a, b, c, d, n_avg)

	# End cap hemisphere
	var fwd_e := (pts[n_pts-1] - pts[n_pts-2]).normalized()
	_hemi_cap.call(pts[n_pts-1], frames[n_pts-1][0], frames[n_pts-1][1], fwd_e)

	return _make_mesh_inst(verts, normals, colors, preset)

# ── Parallel Transport Frame helper ──────────────────────────────
# Trả về frames[i] = [right_i, up_sect_i]
# right_i   = trục ngang trong tiết diện (transported)
# up_sect_i = plane normal tại điểm i (chiều nổi lên)
func _compute_ptf(pts: Array[Vector3], nrms: Array[Vector3]) -> Array:
	var n_pts := pts.size()
	var frames: Array = []

	# Tangent tại mỗi điểm (average 2 segment)
	var tangents: Array[Vector3] = []
	for i in range(n_pts):
		var t: Vector3
		if i == 0:
			t = (pts[1] - pts[0]).normalized()
		elif i == n_pts - 1:
			t = (pts[i] - pts[i-1]).normalized()
		else:
			var ta := (pts[i]   - pts[i-1]).normalized()
			var tb := (pts[i+1] - pts[i]).normalized()
			t = (ta + tb).normalized()
			if t.length() < 0.001: t = ta
		tangents.append(t)

	# Seed frame tại điểm 0: up_sect = plane normal, right = fwd × up_sect
	var up0 := nrms[0].normalized() if not nrms.is_empty() else _plane_normal.normalized()
	up0 = (up0 - tangents[0] * tangents[0].dot(up0)).normalized()
	if up0.length() < 0.001:
		up0 = Vector3.UP if absf(tangents[0].dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var right0 := tangents[0].cross(up0).normalized()
	if right0.length() < 0.001:
		right0 = Vector3.RIGHT if absf(up0.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	frames.append([right0, up0])

	for i in range(1, n_pts):
		var t_prev := tangents[i-1]; var t_curr := tangents[i]
		var r_prev: Vector3 = frames[i-1][0]
		var u_prev: Vector3 = frames[i-1][1]
		var axis   := t_prev.cross(t_curr)
		var angle  := t_prev.angle_to(t_curr)
		var r_new  := r_prev; var u_new := u_prev
		if axis.length() > 0.0001 and absf(angle) > 0.0001:
			var q := Quaternion(axis.normalized(), angle)
			r_new  = q * r_prev
			u_new  = q * u_prev
		# Re-orthogonalize
		r_new = (r_new - t_curr * t_curr.dot(r_new)).normalized()
		u_new = (u_new - t_curr * t_curr.dot(u_new)).normalized()
		if r_new.length() < 0.001: r_new = r_prev
		if u_new.length() < 0.001: u_new = u_prev
		frames.append([r_new, u_new])

	return frames

# ════════════════════════════════════════════════════════════════
#  QUAD / TRI HELPERS
# ════════════════════════════════════════════════════════════════

func _add_quad_2side(
	verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
	a: Vector3, b: Vector3, c: Vector3, d: Vector3,
	n: Vector3, col: Color
) -> void:
	# Front face
	for v in [a, b, c, a, c, d]:
		verts.append(v); normals.append(n); colors.append(col)
	# Back face (reversed winding)
	for v in [a, d, c, a, c, b]:
		verts.append(v); normals.append(-n); colors.append(col)

func _add_tri(
	verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
	a: Vector3, b: Vector3, c: Vector3,
	n: Vector3, col: Color
) -> void:
	for v in [a, b, c]:
		verts.append(v); normals.append(n); colors.append(col)

# ════════════════════════════════════════════════════════════════
#  MESH INSTANCE FACTORY
# ════════════════════════════════════════════════════════════════

func _make_mesh_inst(
	verts:   PackedVector3Array,
	normals: PackedVector3Array,
	colors:  PackedColorArray,
	preset:  BrushPreset
) -> MeshInstance3D:
	if verts.is_empty(): return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR]  = colors
	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh      = amesh
	mi.top_level = false
	mi.set_surface_override_material(0, _build_material())
	return mi

func _build_material() -> ShaderMaterial:
	var mat    := ShaderMaterial.new()
	mat.shader  = _create_shader()
	return mat

func _create_shader() -> Shader:
	var s  := Shader.new()
	s.code  = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform float depth_offset      = 0.0;
uniform float offset_multiplier = 0.01;

void vertex() {
	VERTEX += NORMAL * depth_offset * offset_multiplier;
}

void fragment() {
	vec3 c = COLOR.rgb;
	vec3 linear_color = mix(
		c / 12.92,
		pow((c + 0.055) / 1.055, vec3(2.4)),
		step(0.04045, c)
	);
	ALBEDO = linear_color;
	ALPHA  = COLOR.a;
}
"""
	return s


# erase_at: xoá các điểm trong bán kính, nếu path bị đứt → split thành nhiều StrokeData.
# Trả về Array[StrokeData] mới cần thêm vào plane (có thể rỗng).
# StrokeData gốc bị erase sẽ có points.is_empty() → DrawingPlane filter ra.
func erase_at(world_point: Vector3, strokes: Array, radius: float) -> Array:
	var new_strokes: Array = []

	for data in strokes:
		var sd := data as StrokeData
		if sd == null or sd.points.is_empty() or sd.mesh_inst == null: continue

		var parent_node := sd.mesh_inst.get_parent() as Node3D
		var local_hit   := world_point
		if parent_node:
			local_hit = parent_node.to_local(world_point)

		# Đánh dấu từng điểm: true = giữ lại, false = xoá
		var has_nrm := sd.normals.size() == sd.points.size()
		var keep: Array[bool] = []
		var any_erased := false
		for i in range(sd.points.size()):
			var should_keep := sd.points[i].distance_to(local_hit) > radius
			keep.append(should_keep)
			if not should_keep: any_erased = true

		if not any_erased: continue

		# Build preset tạm
		var temp_preset := BrushPreset.new()
		temp_preset.stroke_type = sd.stroke_type
		temp_preset.shape_type  = sd.shape_type
		temp_preset.size        = sd.size      / BrushPreset.PX_TO_UNIT
		temp_preset.height      = sd.height    / BrushPreset.PX_TO_UNIT
		temp_preset.thickness   = sd.thickness / BrushPreset.PX_TO_UNIT
		temp_preset.opacity     = sd.opacity

		# Tách path thành các đoạn liên tục (segment giữa các điểm bị xoá)
		var segments: Array = []   # mỗi segment = { pts, nrms }
		var seg_pts:  Array[Vector3] = []
		var seg_nrms: Array[Vector3] = []

		for i in range(sd.points.size()):
			if keep[i]:
				seg_pts.append(sd.points[i])
				if has_nrm: seg_nrms.append(sd.normals[i])
			else:
				if seg_pts.size() >= 2:
					segments.append({ "pts": seg_pts.duplicate(), "nrms": seg_nrms.duplicate() })
				seg_pts.clear(); seg_nrms.clear()

		# Đoạn cuối còn lại
		if seg_pts.size() >= 2:
			segments.append({ "pts": seg_pts.duplicate(), "nrms": seg_nrms.duplicate() })

		# Xoá mesh gốc
		sd.mesh_inst.queue_free()
		sd.mesh_inst = null
		sd.points.clear()   # → DrawingPlane sẽ filter ra

		# Tạo StrokeData mới cho mỗi đoạn
		var old_color := current_color
		current_color  = sd.color
		for seg in segments:
			var s_pts:  Array[Vector3] = seg["pts"]
			var s_nrms: Array[Vector3] = seg["nrms"]
			var mi := _build_mesh(s_pts, s_nrms, temp_preset, sd.rng_seed)
			if mi == null: continue
			var new_sd            := StrokeData.new()
			new_sd.mesh_inst       = mi
			new_sd.points          = s_pts
			new_sd.normals         = s_nrms
			new_sd.stroke_type     = sd.stroke_type
			new_sd.shape_type      = sd.shape_type
			new_sd.size            = sd.size
			new_sd.height          = sd.height
			new_sd.thickness       = sd.thickness
			new_sd.opacity         = sd.opacity
			new_sd.color           = sd.color
			new_sd.rng_seed        = sd.rng_seed
			new_sd.render_order    = sd.render_order
			new_strokes.append(new_sd)
		current_color = old_color

	return new_strokes

# ════════════════════════════════════════════════════════════════
#  PUBLIC HELPERS (called from main.gd / drawing_plane.gd)
# ════════════════════════════════════════════════════════════════

func is_drawing() -> bool:
	return not _points.is_empty() or _drag_size_active

func cancel_stroke() -> void:
	_cleanup_preview()
	_points.clear()
	_normals.clear()
	_drag_size_active = false
	_prev_verts.clear(); _prev_normals.clear(); _prev_colors.clear()
	_prev_rings.clear(); _prev_ring_normals.clear()
	_prev_tangents.clear(); _prev_frame_n.clear(); _prev_frame_b.clear()
