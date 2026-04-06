# viewport_gizmo.gd
extends Control

# ─── Refs ────────────────────────────────────────────────────
@onready var sub_viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var gizmo_scene: Node3D       = $SubViewportContainer/SubViewport/GizmoScene
@onready var gizmo_camera: Camera3D    = $SubViewportContainer/SubViewport/GizmoScene/GizmoCamera

var main_camera: Camera3D = null

# ─── Màu ─────────────────────────────────────────────────────
const C_X     := Color(0.92, 0.22, 0.22)
const C_Y     := Color(0.25, 0.78, 0.25)
const C_Z     := Color(0.22, 0.45, 0.92)
const C_NEG   := Color(0.55, 0.55, 0.55)
const C_HOVER := Color(1.00, 1.00, 0.30)
const C_BG    := Color(0.12, 0.12, 0.15, 0.55)

# ─── Định nghĩa axes ─────────────────────────────────────────
# dir: hướng trong world space
# label: chữ hiển thị
# pos: true = đầu dương, false = đầu âm
const AXES := [
	{ "id": "X",  "dir": Vector3( 1, 0, 0), "color": C_X,   "pos": true  },
	{ "id": "-X", "dir": Vector3(-1, 0, 0), "color": C_NEG, "pos": false },
	{ "id": "Y",  "dir": Vector3( 0, 1, 0), "color": C_Y,   "pos": true  },
	{ "id": "-Y", "dir": Vector3( 0,-1, 0), "color": C_NEG, "pos": false },
	{ "id": "Z",  "dir": Vector3( 0, 0, 1), "color": C_Z,   "pos": true  },
	{ "id": "-Z", "dir": Vector3( 0, 0,-1), "color": C_NEG, "pos": false },
]

# Snap targets (yaw, pitch)
const SNAP_ANGLES := {
	"X":  [-90.0,   0.0],   # Right view — nhìn từ +X
	"-X": [ 90.0,   0.0],   # Left view  — nhìn từ -X
	"Y":  [  0.0, -90.0],   # Top view   — nhìn từ +Y
	"-Y": [  0.0,  90.0],   # Bottom view
	"Z":  [180.0,   0.0],   # Front view — nhìn từ +Z
	"-Z": [  0.0,   0.0],   # Back view  — nhìn từ -Z
}

# ─── State ───────────────────────────────────────────────────
var _hovered_id:    String  = ""
var _is_snapping:   bool    = false
var _snap_yaw:      float   = 0.0
var _snap_pitch:    float   = 0.0

# Drag trực tiếp trên gizmo (như Blender)
var _is_dragging:   bool    = false
var _drag_last:     Vector2 = Vector2.ZERO

# ─── Setup ───────────────────────────────────────────────────
func setup(cam: Camera3D) -> void:
	main_camera = cam
	sub_viewport.own_world_3d = true   # ← quan trọng: world riêng
	_build_axis_lines()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

# ─── Build đường kẻ trục bằng ImmediateMesh ──────────────────
func _build_axis_lines() -> void:
	var mi  := MeshInstance3D.new()
	var im  := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode        = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency        = BaseMaterial3D.TRANSPARENCY_ALPHA

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for ax in AXES:
		var col: Color = ax["color"]
		var end: Vector3 = ax["dir"] * (0.75 if ax["pos"] else 0.45)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_set_color(col)
		im.surface_add_vertex(end)
	im.surface_end()

	mi.mesh              = im
	mi.material_override = mat
	gizmo_scene.add_child(mi)

# ─── Update mỗi frame ────────────────────────────────────────
func _process(_delta: float) -> void:
	if main_camera == null:
		return
	# Gizmo scene xoay cùng camera chính — chỉ lấy rotation, không lấy position
	gizmo_scene.global_basis = main_camera.global_basis
	queue_redraw()

# ─── Vẽ dots + labels (2D canvas) ────────────────────────────
func _draw() -> void:
	if main_camera == null:
		return

	var center := size * 0.5
	var r      = min(size.x, size.y) * 0.5 - 10.0

	# Background circle mờ
	draw_circle(center, r + 6.0, C_BG)

	# Sắp xếp theo depth (xa vẽ trước, gần vẽ sau — giống Blender)
	var sorted := _sorted_by_depth()

	for ax in sorted:
		var scr   := _project_dir(ax["dir"], center, r)
		var depth := _get_depth(ax["dir"])  # -1 (xa) đến +1 (gần)

		var is_pos   : bool  = ax["pos"]
		var is_hover : bool  = ax["id"] == _hovered_id
		var col      : Color = C_HOVER if is_hover else ax["color"]
		var dot_r    : float = 10.0 if is_pos else 7.0

		# Dot âm nhỏ hơn, không có label
		draw_circle(scr, dot_r, col)

		# Viền mỏng cho dot dương
		if is_pos:
			draw_arc(scr, dot_r, 0.0, TAU, 24, col.darkened(0.3), 1.0)
			# Label chữ
			var font  := ThemeDB.fallback_font
			var lsize := 11
			var lpos  := scr + Vector2(-font.get_string_size(ax["id"], HORIZONTAL_ALIGNMENT_LEFT, -1, lsize).x * 0.5, 4.0)
			# Shadow nhỏ để dễ đọc
			draw_string(font, lpos + Vector2(1, 1), ax["id"],
						HORIZONTAL_ALIGNMENT_LEFT, -1, lsize, Color(0,0,0,0.6))
			draw_string(font, lpos, ax["id"],
						HORIZONTAL_ALIGNMENT_LEFT, -1, lsize, Color.WHITE)
	if main_camera == null:
		return
	var label := "PERSP" if main_camera.projection == Camera3D.PROJECTION_PERSPECTIVE \
						 else "ORTHO"
	var col   := Color(0.7, 0.7, 0.7, 0.8)
	draw_string(
		ThemeDB.fallback_font,
		Vector2(size.x * 0.5 - 16, size.y - 6),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col
	)

# ─── Helpers projection ──────────────────────────────────────

# Chiếu direction 3D → tọa độ 2D trong gizmo widget
func _project_dir(dir: Vector3, center: Vector2, radius: float) -> Vector2:
	var local := gizmo_scene.global_basis.inverse() * dir
	# Slight perspective: trục gần camera trông to hơn 1 chút
	var scale := 1.0 + local.z * 0.12
	return center + Vector2(local.x, -local.y) * radius * scale

# Depth value để sort (z trong camera space)
func _get_depth(dir: Vector3) -> float:
	var local := gizmo_scene.global_basis.inverse() * dir
	return local.z

# Sort axes: depth nhỏ (xa) trước, depth lớn (gần camera) sau
func _sorted_by_depth() -> Array:
	var arr := AXES.duplicate()
	arr.sort_custom(func(a, b):
		return _get_depth(a["dir"]) < _get_depth(b["dir"])
	)
	return arr

# ─── Hit test ────────────────────────────────────────────────
func _get_hit(mouse_pos: Vector2) -> String:
	var center := size * 0.5
	var r      = min(size.x, size.y) * 0.5 - 10.0

	# Ưu tiên trục gần camera nhất (depth cao nhất)
	var sorted := _sorted_by_depth()
	sorted.reverse()  # gần trước

	for ax in sorted:
		var scr   := _project_dir(ax["dir"], center, r)
		var dot_r := 12.0 if ax["pos"] else 9.0
		if mouse_pos.distance_to(scr) <= dot_r:
			return ax["id"]
	return ""

# ─── GUI Input ───────────────────────────────────────────────
func _gui_input(event: InputEvent) -> void:
	if main_camera == null:
		return

	# Hover
	if event is InputEventMouseMotion:
		_hovered_id = _get_hit(event.position)
		queue_redraw()

		# Drag orbit (giống Blender — drag thẳng trên gizmo)
		if _is_dragging:
			var delta = event.position - _drag_last
			_drag_last = event.position
			main_camera._yaw   -= delta.x * 0.4
			main_camera._pitch -= delta.y * 0.4
			#main_camera._pitch  = clampf(main_camera._pitch, -89.0, 89.0)
			main_camera._apply_transform()
			_is_snapping = false  # cancel snap nếu đang drag

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var hit := _get_hit(event.position)
				if hit != "":
					# Click vào dot → snap
					_start_snap(hit)
				else:
					# Click vào vùng trống → bắt đầu drag orbit
					_is_dragging = true
					_drag_last   = event.position
			else:
				_is_dragging = false

# ─── Snap ────────────────────────────────────────────────────
func _start_snap(id: String) -> void:
	if id not in SNAP_ANGLES:
		return
	_snap_yaw   = SNAP_ANGLES[id][0]
	_snap_pitch = SNAP_ANGLES[id][1]
	_is_snapping = true

func _physics_process(delta: float) -> void:
	if not _is_snapping or main_camera == null:
		return

	var speed := 12.0

	# Lerp góc — xử lý wraparound cho yaw
	var dy := fposmod(_snap_yaw - main_camera._yaw + 180.0, 360.0) - 180.0
	main_camera._yaw   += dy   * speed * delta
	main_camera._pitch  = lerpf(main_camera._pitch, _snap_pitch, speed * delta)

	main_camera._apply_transform()

	# Kết thúc khi đủ gần
	if absf(dy) < 0.05 and absf(main_camera._pitch - _snap_pitch) < 0.05:
		main_camera._yaw   = _snap_yaw
		main_camera._pitch = _snap_pitch
		main_camera._apply_transform()
		_is_snapping = false
