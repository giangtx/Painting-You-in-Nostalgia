# camera_rig.gd
extends Camera3D

# --- Cấu hình ---
@export var orbit_speed: float = 0.005
@export var zoom_speed: float = 0.5
@export var pan_speed: float = 0.01
@export var min_zoom: float = 1.0
@export var max_zoom: float = 30.0

# --- State nội bộ ---
var _pivot: Vector3 = Vector3.ZERO   # điểm camera xoay quanh
var _yaw: float = 30.0               # xoay ngang (độ)
var _pitch: float = -20.0            # xoay dọc (độ)
var _distance: float = 8.0           # khoảng cách tới pivot
var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse: Vector2 = Vector2.ZERO

var _snap_yaw:      float   = 0.0
var _snap_pitch:    float   = 0.0
var _snap_pivot:    Vector3 = Vector3.ZERO
var _snap_distance: float   = 8.0
var _is_snapping:   bool    = false

# Plane đang active — nếu != null thì pivot neo theo plane center
var active_plane: DrawingPlane = null

func _ready() -> void:
	_apply_transform()

func _physics_process(delta: float) -> void:
	if not _is_snapping:
		return

	var speed := 8.0

	# Animate yaw (wraparound)
	var dy  := fposmod(_snap_yaw - _yaw + 180.0, 360.0) - 180.0
	_yaw   += dy * speed * delta
	_pitch  = lerpf(_pitch,    _snap_pitch,    speed * delta)
	# Animate pivot và distance
	_pivot    = _pivot.lerp(_snap_pivot,       speed * delta)
	_distance = lerpf(_distance, _snap_distance, speed * delta)

	if projection == Camera3D.PROJECTION_ORTHOGONAL:
		size = _distance * tan(deg_to_rad(fov * 0.5)) * 2.0

	_apply_transform()

	if absf(dy) < 0.05 and absf(_pitch - _snap_pitch) < 0.05 \
	and _pivot.distance_to(_snap_pivot) < 0.01 \
	and absf(_distance - _snap_distance) < 0.01:
		_yaw      = _snap_yaw
		_pitch    = _snap_pitch
		_pivot    = _snap_pivot
		_distance = _snap_distance
		_is_snapping = false
		_apply_transform()

func _input(event: InputEvent) -> void:
	# --- Bắt đầu / kết thúc orbit (RMB) ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_is_orbiting = event.pressed
			_last_mouse = event.position

		# Bắt đầu / kết thúc pan (MMB)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_last_mouse = event.position

		# Zoom bằng scroll
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = clampf(_distance - zoom_speed, min_zoom, max_zoom)
			if projection == Camera3D.PROJECTION_ORTHOGONAL:
				size = _distance * tan(deg_to_rad(fov * 0.5)) * 2.0
			_apply_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = clampf(_distance + zoom_speed, min_zoom, max_zoom)
			if projection == Camera3D.PROJECTION_ORTHOGONAL:
				size = _distance * tan(deg_to_rad(fov * 0.5)) * 2.0
			_apply_transform()

	# --- Orbit & Pan khi kéo chuột ---
	if event is InputEventMouseMotion:
		var delta = event.position - _last_mouse
		_last_mouse = event.position

		if _is_orbiting:
			_yaw   -= delta.x * orbit_speed * 57.2958  # rad → degree
			_pitch -= delta.y * orbit_speed * 57.2958
			#_pitch = clampf(_pitch, -89.9, 89.9)  # thay vì -89.0, 89.0
			_apply_transform()

		elif _is_panning:
			# Pan dọc theo right và up của camera
			var right = global_basis.x
			var up    = global_basis.y
			var delta_world = -right * delta.x * pan_speed * _distance * 0.1 \
							  + up    * delta.y * pan_speed * _distance * 0.1
			if active_plane != null:
				# Neo pivot — chỉ cho trượt dọc theo mặt plane, không ra ngoài
				var plane_normal := -active_plane.global_basis.z
				# Loại bỏ thành phần vuông góc với plane (không cho pan ra xa)
				delta_world -= plane_normal * delta_world.dot(plane_normal)
			_pivot += delta_world
			_apply_transform()
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_KP_5 or event.keycode == KEY_5:
			_toggle_projection()

# Tính lại vị trí & hướng camera từ _pivot, _yaw, _pitch, _distance
func _apply_transform() -> void:
	var offset = Vector3.ZERO
	offset.x = _distance * cos(deg_to_rad(_pitch)) * sin(deg_to_rad(_yaw))
	offset.y = _distance * sin(deg_to_rad(_pitch))
	offset.z = _distance * cos(deg_to_rad(_pitch)) * cos(deg_to_rad(_yaw))

	global_position = _pivot + offset

	# Build basis thủ công từ yaw/pitch — không dùng look_at
	# → không bị degenerate khi pitch = ±90
	var yaw_rad   := deg_to_rad(_yaw)
	var pitch_rad := deg_to_rad(_pitch)

	# Forward = hướng từ camera về pivot (ngược offset)
	var forward := -offset.normalized()

	# Right = xoay yaw quanh Y
	var right := Vector3(cos(yaw_rad), 0, -sin(yaw_rad))

	# Up = cross(forward, right) đã được normalize
	# nhưng khi pitch = ±90 thì right vẫn đúng vì tính từ yaw
	var up := forward.cross(right).normalized()
	# right lại từ up để đảm bảo orthogonal
	right = up.cross(forward).normalized()

	global_basis = Basis(right, up, -forward)

# Hàm public để các script khác lấy depth chuẩn (dùng ở Giai đoạn 2)
func get_guide_depth() -> float:
	return _distance * 0.6

func _toggle_projection() -> void:
	if projection == Camera3D.PROJECTION_PERSPECTIVE:
		projection       = Camera3D.PROJECTION_ORTHOGONAL
		# Size của ortho tương đương với khoảng cách hiện tại
		# để không bị jump đột ngột khi chuyển
		size             = _distance * tan(deg_to_rad(fov * 0.5)) * 2.0
	else:
		projection       = Camera3D.PROJECTION_PERSPECTIVE
		
func snap_to_plane(plane_normal: Vector3) -> void:
	var dir     := -plane_normal.normalized()
	_snap_pitch  = rad_to_deg(asin(clampf(-dir.y, -1.0, 1.0)))
	_snap_yaw    = rad_to_deg(atan2(-dir.x, -dir.z))
	_is_snapping = true

# Focus mượt về một vị trí — animate pivot + distance + angle cùng lúc
func focus_on(target_pivot: Vector3, target_distance: float, plane_normal: Vector3 = Vector3.ZERO) -> void:
	_snap_pivot    = target_pivot
	_snap_distance = clampf(target_distance, min_zoom, max_zoom)
	if plane_normal != Vector3.ZERO:
		var dir     := -plane_normal.normalized()
		_snap_pitch  = rad_to_deg(asin(clampf(-dir.y, -1.0, 1.0)))
		_snap_yaw    = rad_to_deg(atan2(-dir.x, -dir.z))
	else:
		# Giữ nguyên góc nhìn hiện tại
		_snap_pitch = _pitch
		_snap_yaw   = _yaw
	_is_snapping = true

# Đặt pivot ngay lập tức (không animate)
func set_pivot(pos: Vector3) -> void:
	_pivot       = pos
	_snap_pivot  = pos
	_apply_transform()

# Set distance ngay lập tức (không animate)
func set_distance(d: float) -> void:
	_distance       = clampf(d, min_zoom, max_zoom)
	_snap_distance  = _distance
	if projection == Camera3D.PROJECTION_ORTHOGONAL:
		size = _distance * tan(deg_to_rad(fov * 0.5)) * 2.0
	_apply_transform()

# Tính điểm gần camera nhất trên plane rồi set làm pivot
# plane_pos: vị trí bất kỳ trên plane, plane_normal: normal của plane
func snap_pivot_to_plane(plane_pos: Vector3, plane_normal: Vector3) -> void:
	# Project vị trí camera hiện tại xuống plane → điểm gần nhất
	var gdplane    := Plane(plane_normal.normalized(), plane_pos)
	var projected  := gdplane.project(global_position)
	set_pivot(projected)
