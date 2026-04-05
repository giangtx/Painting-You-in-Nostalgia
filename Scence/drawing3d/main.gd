# main.gd
extends Node3D

# ─── Refs ─────────────────────────────────────────────────────
@onready var camera:          Camera3D    = $Camera
@onready var grid:            MeshInstance3D = $DrawingWorld/GridHelper
@onready var gizmo:           Control     = $GizmoContainer
@onready var guide_drawer:    Node        = $GuideDrawer
@onready var plane_container: Node3D      = $DrawingWorld/PlaneContainer

# Preview canvas — vẽ đường guide lên màn hình
var _preview_canvas: CanvasLayer
var _preview_line:   Line2D

# Mode hiện tại
enum Mode { DRAW, GUIDE }
var _mode: Mode = Mode.DRAW

# Plane đang active (sẽ dùng ở giai đoạn 3)
var _active_plane: DrawingPlane = null

# Preload scene
const DrawingPlaneScene = preload("res://Scence/drawing3d/DrawingPlane.tscn")

func _ready() -> void:
	gizmo.setup(camera)
	_setup_preview_canvas()

	# Setup guide drawer
	guide_drawer.setup(camera, _preview_canvas)
	guide_drawer.guide_finished.connect(_on_guide_finished)

# ─── Tạo canvas vẽ preview guide ──────────────────────────────
func _setup_preview_canvas() -> void:
	_preview_canvas = CanvasLayer.new()
	add_child(_preview_canvas)

	_preview_line             = Line2D.new()
	_preview_line.width       = 2.0
	_preview_line.default_color = Color(1.0, 0.85, 0.2, 0.9)   # vàng
	_preview_line.antialiased = true
	_preview_canvas.add_child(_preview_line)

# ─── Input ────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	# Phím tắt
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_G: grid.toggle()
			KEY_F: _reset_camera()
			KEY_ESCAPE: _cancel_guide()

	# Shift + LMB → Guide mode
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var shift_held := Input.is_key_pressed(KEY_SHIFT)

		if event.pressed:
			if shift_held:
				_mode = Mode.GUIDE
				guide_drawer.start_guide(event.position)
		else:
			if _mode == Mode.GUIDE:
				guide_drawer.finish_guide()
				_mode = Mode.DRAW

	# Thu thập điểm khi đang vẽ guide
	if event is InputEventMouseMotion:
		if _mode == Mode.GUIDE:
			guide_drawer.add_point(event.position)
			_update_preview()

# ─── Cập nhật đường preview ───────────────────────────────────
func _update_preview() -> void:
	_preview_line.clear_points()
	for p in guide_drawer.get_screen_points():
		_preview_line.add_point(p)

# ─── Callback khi guide hoàn thành ────────────────────────────
func _on_guide_finished(points_3d: Array) -> void:
	_preview_line.clear_points()

	var data := SurfaceGenerator.compute(points_3d, camera)
	if data.is_empty():
		return

	if _active_plane != null:
		_active_plane.visible = false

	var plane: DrawingPlane = DrawingPlaneScene.instantiate()
	plane_container.add_child(plane)
	plane.initialize(data)
	_active_plane = plane

	if data["normal"] != Vector3.ZERO:
		camera.snap_to_plane(data["normal"])
# ─── Huỷ guide đang vẽ ────────────────────────────────────────
func _cancel_guide() -> void:
	guide_drawer.cancel()
	_preview_line.clear_points()
	_mode = Mode.DRAW

# ─── Reset camera ─────────────────────────────────────────────
func _reset_camera() -> void:
	camera._pivot    = Vector3.ZERO
	camera._distance = 8.0
	camera._yaw      = 30.0
	camera._pitch    = -20.0
	camera._apply_transform()
