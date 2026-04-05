# guide_drawer.gd
extends Node

# ─── Signal ──────────────────────────────────────────────────
# Phát khi user thả chuột — truyền danh sách điểm 3D đã unproject
signal guide_finished(points_3d: Array)

# ─── Refs ─────────────────────────────────────────────────────
var main_camera: Camera3D = null
var draw_layer: CanvasLayer = null   # để vẽ preview 2D

# ─── State ────────────────────────────────────────────────────
var _is_drawing:    bool            = false
var _screen_points: Array[Vector2]  = []

# Khoảng cách tối thiểu giữa 2 điểm liên tiếp (tránh điểm trùng)
const MIN_DIST := 4.0
# Số điểm tối thiểu để coi là hợp lệ
const MIN_POINTS := 3
var _dpi_scale: Vector2 = Vector2.ONE

func setup(cam: Camera3D, canvas: CanvasLayer) -> void:
	main_camera = cam
	draw_layer  = canvas

# ─── Bắt đầu vẽ ───────────────────────────────────────────────
func start_guide(screen_pos: Vector2) -> void:
	_is_drawing    = true
	_screen_points = []
	_screen_points.append(screen_pos)

# ─── Thêm điểm trong khi drag ─────────────────────────────────
func add_point(screen_pos: Vector2) -> void:
	if not _is_drawing:
		return
	var last = _screen_points.back()
	if screen_pos.distance_to(last) >= MIN_DIST:
		_screen_points.append(screen_pos)

# ─── Kết thúc — unproject & emit ──────────────────────────────
func finish_guide() -> void:
	if not _is_drawing:
		return
	_is_drawing = false

	if _screen_points.size() < MIN_POINTS:
		_screen_points.clear()
		return

	var points_3d := _unproject_all()
	_screen_points.clear()
	guide_finished.emit(points_3d)

func cancel() -> void:
	_is_drawing    = false
	_screen_points.clear()

func is_drawing() -> bool:
	return _is_drawing

# ─── Unproject screen → 3D ────────────────────────────────────
func _unproject_all() -> Array:
	var result: Array = []
	var cam_fwd := -main_camera.global_basis.z

	var plane_pos: Vector3
	if main_camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		plane_pos = main_camera._pivot
	else:
		var depth := _get_guide_depth()
		plane_pos = main_camera.global_position + cam_fwd * depth

	var proj_plane := Plane(cam_fwd, plane_pos)

	for sp in _screen_points:
		# Dùng thẳng sp — không scale
		var origin := main_camera.project_ray_origin(sp)
		var dir    := main_camera.project_ray_normal(sp)
		var intersection = proj_plane.intersects_ray(origin, dir)
		if intersection != null:
			result.append(intersection)

	return result

# Depth tính từ FOV — giống Feather:
# zoom in → plane gần hơn, zoom out → plane xa hơn
# nhưng kích thước "thực" của plane trong world luôn ổn định
func _get_guide_depth() -> float:
	if main_camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		# Orthographic: dùng khoảng cách camera tới pivot
		return main_camera._distance
	else:
		var fov_rad := deg_to_rad(main_camera.fov)
		return 3.0 / tan(fov_rad * 0.5)

# ─── Lấy điểm screen để vẽ preview (gọi từ Main) ─────────────
func get_screen_points() -> Array[Vector2]:
	return _screen_points
