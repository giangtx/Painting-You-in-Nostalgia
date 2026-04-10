# plane_gizmo.gd
# Gizmo kiểu Blender — arrow translate + ring rotate cho DrawingPlane
# Scale theo khoảng cách camera, hit test bằng screen-space pixel distance
class_name PlaneGizmo
extends Node3D

# ─── Signals ──────────────────────────────────────────────────
signal transform_changed

# ─── Refs ─────────────────────────────────────────────────────
var _camera: Camera3D     = null
var _plane:  DrawingPlane = null

# ─── Màu sắc ──────────────────────────────────────────────────
const C_X         := Color(0.92, 0.22, 0.22)
const C_Y         := Color(0.25, 0.78, 0.25)
const C_Z         := Color(0.22, 0.45, 0.92)
const C_HOVER     := Color(1.00, 1.00, 0.20)
const C_ACTIVE    := Color(1.00, 0.80, 0.00)

# ─── Tỉ lệ kích thước (đơn vị: tỉ lệ với khoảng cách camera) ─
# Tất cả kích thước WORLD được tính = hằng số này × _gizmo_scale mỗi frame
# → gizmo luôn to bằng nhau trên màn hình dù zoom in/out
const ARROW_LEN_RATIO   := 0.28   # chiều dài arrow = 18% khoảng cách camera
const ARROW_HEAD_RATIO  := 0.035  # đầu mũi tên
const RING_RADIUS_RATIO := 0.22   # bán kính ring

# ─── Hit test (screen-space pixels) ──────────────────────────
# Đây là ngưỡng PIXEL — không phụ thuộc khoảng cách → luôn dễ click
const ARROW_HIT_PX  := 12.0   # pixel tolerance cho arrow
const RING_HIT_PX   := 14.0   # pixel tolerance cho ring
const PLANE_HIT_PX  := 14.0   # pixel tolerance cho plane square
const PLANE_SIZE_RATIO := 0.055  # kích thước hình vuông
const PLANE_OFFSET_RATIO := 0.09 # offset từ gốc ra mặt phẳng

# ─── Enum handle ─────────────────────────────────────────────
enum HandleType { NONE, TRANS_X, TRANS_Y, TRANS_Z,
				  TRANS_XY, TRANS_XZ, TRANS_YZ,
				  ROT_X, ROT_Y, ROT_Z }

# ─── State ───────────────────────────────────────────────────
var _hovered_handle:   HandleType = HandleType.NONE
var _active_handle:    HandleType = HandleType.NONE
var _drag_start_mouse: Vector2    = Vector2.ZERO
var _drag_prev_mouse:  Vector2    = Vector2.ZERO  # [NEW] cho incremental rotate
var _drag_start_pos:   Vector3    = Vector3.ZERO
var _drag_start_basis: Basis      = Basis.IDENTITY
var _drag_axis_world:  Vector3    = Vector3.ZERO
var _drag_plane_pt:    Vector3    = Vector3.ZERO  # [FIX] anchor tại hit point đầu tiên
var _drag_accumulated_angle: float = 0.0          # [NEW] tổng góc xoay từ start

# Scale world hiện tại — tính lại mỗi frame từ khoảng cách camera
var _gizmo_scale: float = 1.0

# ─── Mesh instances ───────────────────────────────────────────
var _arrow_meshes: Array[MeshInstance3D] = []   # 3 arrows X/Y/Z
var _ring_meshes:  Array[MeshInstance3D] = []   # 3 rings X/Y/Z
var _plane_meshes: Array[MeshInstance3D] = []   # 3 plane squares XY/XZ/YZ

# ─── Setup / Attach / Detach ─────────────────────────────────
func setup(camera: Camera3D) -> void:
	_camera = camera
	visible = false
	_build_meshes()

func attach(plane: DrawingPlane) -> void:
	_plane   = plane
	visible  = (plane != null)
	_hovered_handle = HandleType.NONE
	_active_handle  = HandleType.NONE

func detach() -> void:
	_plane   = null
	visible  = false
	_hovered_handle = HandleType.NONE
	_active_handle  = HandleType.NONE

# ─── Build mesh containers ────────────────────────────────────
func _build_meshes() -> void:
	for m in _arrow_meshes: m.queue_free()
	for m in _ring_meshes:  m.queue_free()
	for m in _plane_meshes: m.queue_free()
	_arrow_meshes.clear()
	_ring_meshes.clear()
	_plane_meshes.clear()

	for i in 3:
		var mat := _make_mat()
		var mi  := MeshInstance3D.new()
		mi.mesh              = ImmediateMesh.new()
		mi.material_override = mat
		add_child(mi)
		_arrow_meshes.append(mi)

	for i in 3:
		var mat := _make_mat()
		var mi  := MeshInstance3D.new()
		mi.mesh              = ImmediateMesh.new()
		mi.material_override = mat
		add_child(mi)
		_ring_meshes.append(mi)

	for i in 3:
		var mat := _make_mat()
		var mi  := MeshInstance3D.new()
		mi.mesh              = ImmediateMesh.new()
		mi.material_override = mat
		add_child(mi)
		_plane_meshes.append(mi)

func _make_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.flags_no_depth_test        = true   # luôn render trên foreground
	return mat

# ─── Process: update scale + position + redraw ───────────────
func _process(_delta: float) -> void:
	if not visible or _plane == null or _camera == null:
		return

	# Gizmo đặt tại center plane, orientation theo plane
	global_position = _plane.global_position
	global_basis    = _plane.global_basis

	# Scale tỉ lệ với khoảng cách camera → constant screen size
	_gizmo_scale = _camera.global_position.distance_to(global_position)
	if _gizmo_scale < 0.001:
		_gizmo_scale = 0.001

	# Redraw tất cả handle với màu và kích thước hiện tại
	_redraw_all()

# ─── Redraw ───────────────────────────────────────────────────
func _redraw_all() -> void:
	var arrow_dirs   := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var ring_normals := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var base_colors  := [C_X, C_Y, C_Z]
	var trans_types  := [HandleType.TRANS_X, HandleType.TRANS_Y, HandleType.TRANS_Z]
	var rot_types    := [HandleType.ROT_X,   HandleType.ROT_Y,   HandleType.ROT_Z  ]
	# Plane squares: XY (normal Z), XZ (normal Y), YZ (normal X)
	# dir_a, dir_b = 2 trục của mặt phẳng; color = mix 2 màu
	var plane_types  := [HandleType.TRANS_XY, HandleType.TRANS_XZ, HandleType.TRANS_YZ]
	var plane_dir_a  := [Vector3.RIGHT, Vector3.RIGHT, Vector3.UP  ]
	var plane_dir_b  := [Vector3.UP,    Vector3.BACK,  Vector3.BACK ]
	var plane_colors := [Color(C_X.r, C_X.r * 0.3 + C_Y.r * 0.7, C_Y.b, 0.5),
						 Color(C_X.r, C_X.g * 0.3 + C_Z.g * 0.7, C_Z.b, 0.5),
						 Color(C_Y.r * 0.3 + C_Z.r * 0.7, C_Y.g, C_Z.b, 0.5)]

	for i in 3:
		var col := _resolve_color(trans_types[i], base_colors[i])
		_draw_arrow(_arrow_meshes[i].mesh as ImmediateMesh, arrow_dirs[i], col)

	for i in 3:
		var col := _resolve_color(rot_types[i], base_colors[i])
		_draw_ring(_ring_meshes[i].mesh as ImmediateMesh, ring_normals[i], col)

	for i in 3:
		var col := _resolve_color(plane_types[i], plane_colors[i])
		_draw_plane_square(_plane_meshes[i].mesh as ImmediateMesh,
						   plane_dir_a[i], plane_dir_b[i], col)

func _draw_plane_square(im: ImmediateMesh, dir_a: Vector3, dir_b: Vector3, col: Color) -> void:
	im.clear_surfaces()
	var s   := PLANE_SIZE_RATIO   * _gizmo_scale  # kích thước cạnh
	var off := PLANE_OFFSET_RATIO * _gizmo_scale  # offset từ gốc

	# Center của hình vuông nằm trên đường phân giác của 2 trục
	var center := (dir_a + dir_b).normalized() * off * 1.2

	# 4 góc của hình vuông trong mặt phẳng dir_a/dir_b
	var hs := s * 0.5
	var c0 := center - dir_a * hs - dir_b * hs
	var c1 := center + dir_a * hs - dir_b * hs
	var c2 := center + dir_a * hs + dir_b * hs
	var c3 := center - dir_a * hs + dir_b * hs

	# Vẽ filled quad bằng TRIANGLES + outline bằng LINES
	# Filled (dùng color với alpha thấp hơn để trong suốt một chút)
	var fill_col := Color(col.r, col.g, col.b, col.a * 0.4)
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	im.surface_set_color(fill_col); im.surface_add_vertex(c0)
	im.surface_set_color(fill_col); im.surface_add_vertex(c1)
	im.surface_set_color(fill_col); im.surface_add_vertex(c2)
	im.surface_set_color(fill_col); im.surface_add_vertex(c0)
	im.surface_set_color(fill_col); im.surface_add_vertex(c2)
	im.surface_set_color(fill_col); im.surface_add_vertex(c3)
	im.surface_end()

	# Outline
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(col); im.surface_add_vertex(c0)
	im.surface_set_color(col); im.surface_add_vertex(c1)
	im.surface_set_color(col); im.surface_add_vertex(c1)
	im.surface_set_color(col); im.surface_add_vertex(c2)
	im.surface_set_color(col); im.surface_add_vertex(c2)
	im.surface_set_color(col); im.surface_add_vertex(c3)
	im.surface_set_color(col); im.surface_add_vertex(c3)
	im.surface_set_color(col); im.surface_add_vertex(c0)
	im.surface_end()

func _resolve_color(handle: HandleType, base: Color) -> Color:
	if handle == _active_handle:
		return C_ACTIVE
	if handle == _hovered_handle:
		return C_HOVER
	return base

# ─── Draw arrow (local space, scale applied) ─────────────────
func _draw_arrow(im: ImmediateMesh, dir: Vector3, col: Color) -> void:
	im.clear_surfaces()
	var len  := ARROW_LEN_RATIO  * _gizmo_scale
	var head := ARROW_HEAD_RATIO * _gizmo_scale
	var tip  := dir * len
	var base := dir * (len - head)

	var perp1 := dir.cross(Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT).normalized()
	var perp2 := dir.cross(perp1).normalized()

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	# Thân
	im.surface_set_color(col); im.surface_add_vertex(Vector3.ZERO)
	im.surface_set_color(col); im.surface_add_vertex(tip)
	# Đầu mũi tên — 4 cạnh
	for k in 4:
		var a   := k * PI * 0.5
		var off := (perp1 * cos(a) + perp2 * sin(a)) * head * 0.45
		im.surface_set_color(col); im.surface_add_vertex(tip)
		im.surface_set_color(col); im.surface_add_vertex(base + off)
	im.surface_end()

# ─── Draw ring (local space, scale applied) ──────────────────
func _draw_ring(im: ImmediateMesh, normal: Vector3, col: Color) -> void:
	im.clear_surfaces()
	var r    := RING_RADIUS_RATIO * _gizmo_scale
	var segs := 64
	var ref  := normal.cross(Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT).normalized()
	var perp := normal.cross(ref).normalized()

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in segs:
		var a0 := (float(i)     / segs) * TAU
		var a1 := (float(i + 1) / segs) * TAU
		var p0 := (ref * cos(a0) + perp * sin(a0)) * r
		var p1 := (ref * cos(a1) + perp * sin(a1)) * r
		im.surface_set_color(col); im.surface_add_vertex(p0)
		im.surface_set_color(col); im.surface_add_vertex(p1)
	im.surface_end()

# ─── Hit test (screen-space) ─────────────────────────────────
func get_handle_at(screen_pos: Vector2) -> HandleType:
	if not visible or _camera == null:
		return HandleType.NONE

	var best      := HandleType.NONE
	var best_dist := INF

	var len    := ARROW_LEN_RATIO  * _gizmo_scale
	var radius := RING_RADIUS_RATIO * _gizmo_scale
	var origin := global_position
	var cam_fwd := -_camera.global_basis.z

	# Arrow world dirs phải match với local dirs dùng trong _redraw_all:
	# Vector3.RIGHT  → global_basis.x
	# Vector3.UP     → global_basis.y
	# Vector3.BACK   → +global_basis.z  (BACK = (0,0,1) local = +z world)
	var arrow_world_dirs := [global_basis.x, global_basis.y, global_basis.z]
	var arrow_types      := [HandleType.TRANS_X, HandleType.TRANS_Y, HandleType.TRANS_Z]

	# Pass 1: test các arrow có dot thấp trước (arrow rõ ràng trên screen)
	# Pass 2: test arrow có dot cao (gần song song camera) — override nếu mouse gần origin
	var deferred_high_dot: Array = []  # [index, dot] để xử lý sau

	for i in 3:
		var dir = arrow_world_dirs[i]
		var dot := absf(dir.dot(cam_fwd))
		var p0  := _camera.unproject_position(origin)
		var p1  := _camera.unproject_position(origin + dir * len)

		if dot > 0.7:
			deferred_high_dot.append([i, dot])
			continue

		var d_seg := _dist_point_to_segment_2d(screen_pos, p0, p1)
		var d_tip := screen_pos.distance_to(p1)
		var d     := minf(d_seg, d_tip)
		if d < ARROW_HIT_PX and d < best_dist:
			best_dist = d
			best      = arrow_types[i]

	# High-dot arrows: chỉ hit nếu mouse thực sự gần origin và không có arrow rõ nào win
	for entry in deferred_high_dot:
		var i   : int   = entry[0]
		var dot : float = entry[1]
		var p0          := _camera.unproject_position(origin)
		var thresh      := lerpf(ARROW_HIT_PX, ARROW_HIT_PX * 3.0, (dot - 0.7) / 0.3)
		var d           := screen_pos.distance_to(p0)
		# Override best hanya jika mouse lebih dekat ke origin dari best_dist saat ini
		if d < thresh and d < best_dist:
			best_dist = d
			best      = arrow_types[entry[0]]

	# Ring hit test — sample điểm trên ring, tìm khoảng cách pixel nhỏ nhất
	# Ring normals cũng match local dirs: BACK = +global_basis.z
	var ring_world_normals := [global_basis.x, global_basis.y, global_basis.z]
	var ring_types         := [HandleType.ROT_X, HandleType.ROT_Y, HandleType.ROT_Z]
	var segs := 64
	for i in 3:
		var n    = ring_world_normals[i]
		var ref  = n.cross(Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT).normalized()
		var perp = n.cross(ref).normalized()
		var min_d := INF
		for k in segs:
			var a  := (float(k) / segs) * TAU
			var wp = origin + (ref * cos(a) + perp * sin(a)) * radius
			var sp := _camera.unproject_position(wp)
			min_d = minf(min_d, sp.distance_to(screen_pos))
		if min_d < RING_HIT_PX and min_d < best_dist:
			best_dist = min_d
			best      = ring_types[i]

	# Plane square hit test — point-in-quad 2D
	var plane_types := [HandleType.TRANS_XY, HandleType.TRANS_XZ, HandleType.TRANS_YZ]
	var plane_dir_a := [global_basis.x, global_basis.x, global_basis.y]
	var plane_dir_b := [global_basis.y, global_basis.z, global_basis.z]
	var sq          := PLANE_SIZE_RATIO   * _gizmo_scale
	var sq_off      := PLANE_OFFSET_RATIO * _gizmo_scale
	for i in 3:
		var da     = plane_dir_a[i]
		var db     = plane_dir_b[i]
		var center = origin + (da + db).normalized() * sq_off * 1.2
		var hs     := sq * 0.5
		var sc0    := _camera.unproject_position(center - da * hs - db * hs)
		var sc1    := _camera.unproject_position(center + da * hs - db * hs)
		var sc2    := _camera.unproject_position(center + da * hs + db * hs)
		var sc3    := _camera.unproject_position(center - da * hs + db * hs)
		if _point_in_triangle_2d(screen_pos, sc0, sc1, sc2) or \
		   _point_in_triangle_2d(screen_pos, sc0, sc2, sc3):
			var d := screen_pos.distance_to((sc0 + sc2) * 0.5)
			if d < best_dist:
				best_dist = d
				best      = plane_types[i]

	return best

func _point_in_triangle_2d(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (p - b).cross(a - b)
	var d2 := (p - c).cross(b - c)
	var d3 := (p - a).cross(c - a)
	var has_neg := (d1 < 0) or (d2 < 0) or (d3 < 0)
	var has_pos := (d1 > 0) or (d2 > 0) or (d3 > 0)
	return not (has_neg and has_pos)

func _dist_point_to_segment_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab   := b - a
	var len2 := ab.dot(ab)
	if len2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)

# ─── Hover update (gọi từ main.gd mỗi MouseMotion) ───────────
func update_hover(screen_pos: Vector2) -> bool:
	if not visible:
		return false
	var h := get_handle_at(screen_pos)
	if h != _hovered_handle:
		_hovered_handle = h
		# _redraw_all được gọi ở _process → tự update màu
	return h != HandleType.NONE

# ─── Drag start ───────────────────────────────────────────────
func start_drag(screen_pos: Vector2) -> bool:
	var h := get_handle_at(screen_pos)
	if h == HandleType.NONE:
		return false

	_active_handle         = h
	_hovered_handle        = HandleType.NONE
	_drag_start_mouse      = screen_pos
	_drag_prev_mouse       = screen_pos   # [NEW]
	_drag_start_pos        = _plane.global_position
	_drag_start_basis      = _plane.global_basis
	_drag_accumulated_angle = 0.0        # [NEW]

	match h:
		HandleType.TRANS_X:  _drag_axis_world = _plane.global_basis.x
		HandleType.TRANS_Y:  _drag_axis_world = _plane.global_basis.y
		HandleType.TRANS_Z:  _drag_axis_world = _plane.global_basis.z
		HandleType.TRANS_XY: _drag_axis_world = Vector3.ZERO  # 2-axis, handled separately
		HandleType.TRANS_XZ: _drag_axis_world = Vector3.ZERO
		HandleType.TRANS_YZ: _drag_axis_world = Vector3.ZERO
		HandleType.ROT_X:    _drag_axis_world = _plane.global_basis.x
		HandleType.ROT_Y:    _drag_axis_world = _plane.global_basis.y
		HandleType.ROT_Z:    _drag_axis_world = _plane.global_basis.z

	# [FIX] Anchor drag plane tại điểm giao tia chuột với plane camera-facing
	# → scale translate 1:1 với mouse dù camera gần hay xa
	var cam_fwd    := -_camera.global_basis.z
	var near_plane := Plane(cam_fwd, _plane.global_position)
	var ray_o      := _camera.project_ray_origin(screen_pos)
	var ray_d      := _camera.project_ray_normal(screen_pos)
	var hit        = near_plane.intersects_ray(ray_o, ray_d)
	_drag_plane_pt  = hit if hit != null else _plane.global_position
	return true

# ─── Drag update ──────────────────────────────────────────────
func update_drag(screen_pos: Vector2) -> void:
	if _active_handle == HandleType.NONE or _plane == null:
		return

	match _active_handle:
		HandleType.TRANS_X, HandleType.TRANS_Y, HandleType.TRANS_Z:
			_do_translate(screen_pos)
		HandleType.TRANS_XY, HandleType.TRANS_XZ, HandleType.TRANS_YZ:
			_do_translate_plane(screen_pos)
		HandleType.ROT_X, HandleType.ROT_Y, HandleType.ROT_Z:
			_do_rotate(screen_pos)
			_drag_prev_mouse = screen_pos  # [NEW] update prev sau mỗi frame rotate

	transform_changed.emit()

func _do_translate(screen_pos: Vector2) -> void:
	var cam_fwd    := -_camera.global_basis.z
	var proj_plane := Plane(cam_fwd, _drag_plane_pt)
	var o0 := _camera.project_ray_origin(_drag_start_mouse)
	var d0 := _camera.project_ray_normal(_drag_start_mouse)
	var o1 := _camera.project_ray_origin(screen_pos)
	var d1 := _camera.project_ray_normal(screen_pos)
	var h0 = proj_plane.intersects_ray(o0, d0)
	var h1 = proj_plane.intersects_ray(o1, d1)
	if h0 == null or h1 == null:
		return
	var world_delta = h1 - h0
	var projected   = _drag_axis_world * world_delta.dot(_drag_axis_world)
	_plane.global_position = _drag_start_pos + projected

func _do_translate_plane(screen_pos: Vector2) -> void:
	# Di chuyển tự do trên mặt phẳng 2 trục — unproject lên mặt phẳng của handle
	# Mặt phẳng này là mặt phẳng vuông góc với trục còn lại
	var plane_normal: Vector3
	match _active_handle:
		HandleType.TRANS_XY: plane_normal = _drag_start_basis.z   # mặt phẳng XY vuông góc Z
		HandleType.TRANS_XZ: plane_normal = _drag_start_basis.y   # mặt phẳng XZ vuông góc Y
		HandleType.TRANS_YZ: plane_normal = _drag_start_basis.x   # mặt phẳng YZ vuông góc X
		_: plane_normal = -_camera.global_basis.z

	var proj_plane := Plane(plane_normal.normalized(), _drag_plane_pt)
	var o0 := _camera.project_ray_origin(_drag_start_mouse)
	var d0 := _camera.project_ray_normal(_drag_start_mouse)
	var o1 := _camera.project_ray_origin(screen_pos)
	var d1 := _camera.project_ray_normal(screen_pos)
	var h0 = proj_plane.intersects_ray(o0, d0)
	var h1 = proj_plane.intersects_ray(o1, d1)
	if h0 == null or h1 == null:
		return
	_plane.global_position = _drag_start_pos + (h1 - h0)

func _do_rotate(screen_pos: Vector2) -> void:
	var dx          := screen_pos.x - _drag_prev_mouse.x
	var delta_angle := dx * 0.005

	_drag_accumulated_angle += delta_angle

	# [FIX] Dùng trục từ _drag_start_basis thay vì _drag_axis_world
	# _drag_axis_world là world-space tại thời điểm start_drag → stale sau khi plane rotate
	# _drag_start_basis snapshot basis của plane lúc bắt đầu → luôn đúng
	var axis: Vector3
	match _active_handle:
		HandleType.ROT_X: axis = _drag_start_basis.x
		HandleType.ROT_Y: axis = _drag_start_basis.y
		_:                axis = _drag_start_basis.z   # ROT_Z: BACK = +z

	var q               := Quaternion(axis, _drag_accumulated_angle)
	_plane.global_basis  = Basis(q) * _drag_start_basis

# ─── Drag end ─────────────────────────────────────────────────
func end_drag() -> void:
	_active_handle = HandleType.NONE

func is_dragging() -> bool:
	return _active_handle != HandleType.NONE
