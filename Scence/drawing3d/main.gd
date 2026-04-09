# main.gd
extends Node3D

@onready var camera:          Camera3D       = $Camera
@onready var grid:            MeshInstance3D = $DrawingWorld/GridHelper
@onready var gizmo:           Control        = $GizmoContainer
@onready var guide_drawer:    Node           = $GuideDrawer
@onready var plane_container: Node3D         = $DrawingWorld/PlaneContainer
@onready var stroke_builder:  StrokeBuilder  = $StrokeBuilder
@onready var _brush_panel                    = $CanvasLayer/BrushPanel

var _preview_canvas: CanvasLayer
var _preview_line:   Line2D

enum Mode { DRAW, GUIDE, ERASE }
var _mode: Mode = Mode.DRAW

var _active_plane: DrawingPlane = null

const DrawingPlaneScene = preload("res://Scence/drawing3d/DrawingPlane.tscn")

func _ready() -> void:
	gizmo.setup(camera)
	_setup_preview_canvas()
	guide_drawer.setup(camera, _preview_canvas)
	guide_drawer.guide_finished.connect(_on_guide_finished)
	_setup_brush_panel()

func _setup_preview_canvas() -> void:
	_preview_canvas             = CanvasLayer.new()
	add_child(_preview_canvas)
	_preview_line               = Line2D.new()
	_preview_line.width         = 2.0
	_preview_line.default_color = Color(1.0, 0.85, 0.2, 0.9)
	_preview_line.antialiased   = true
	_preview_canvas.add_child(_preview_line)

func _setup_brush_panel() -> void:
	var init_size := stroke_builder.get_current_preset().brush_size \
					 if stroke_builder.get_current_preset() else 0.08
	_brush_panel.setup(stroke_builder.brushes, stroke_builder.current_color, init_size)
	_brush_panel.brush_changed.connect(_on_panel_brush_changed)
	_brush_panel.brush_size_changed.connect(_on_panel_size_changed)
	_brush_panel.color_changed.connect(_on_panel_color_changed)
	_brush_panel.mode_changed.connect(_on_panel_mode_changed)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_G:      grid.toggle()
			KEY_F:      _reset_camera()
			KEY_ESCAPE: _cancel_all()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var shift_held := Input.is_key_pressed(KEY_SHIFT)
		var e_held     := Input.is_key_pressed(KEY_E)

		if event.pressed:
			if e_held:
				# Phím tắt: force ERASE tạm thời dù panel đang ở mode nào
				_set_mode(Mode.ERASE)
				stroke_builder.cancel_stroke()
				guide_drawer.cancel()
			elif shift_held:
				_set_mode(Mode.GUIDE)
				stroke_builder.cancel_stroke()
				guide_drawer.start_guide(event.position)
			elif _mode == Mode.ERASE:
				# Panel đã chọn ERASE → không override về DRAW
				pass
			else:
				_set_mode(Mode.DRAW)
				_start_stroke(event.position)
		else:  # released
			if _mode == Mode.GUIDE:
				guide_drawer.finish_guide()
				_set_mode(Mode.DRAW)
			elif _mode == Mode.DRAW:
				_finish_stroke()
			# ERASE: không reset mode khi thả — giữ để user tiếp tục xoá

	if event is InputEventMouseMotion:
		if _mode == Mode.GUIDE:
			guide_drawer.add_point(event.position)
			_update_preview()
		elif _mode == Mode.DRAW and stroke_builder.is_drawing():
			_continue_stroke(event.position)
		elif _mode == Mode.ERASE and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_do_erase(event.position)

# ─── Đồng bộ mode ─────────────────────────────────────────────
func _set_mode(m: Mode) -> void:
	_mode = m
	if _brush_panel:
		var panel_mode := 1 if m == Mode.ERASE else 0
		_brush_panel.set_mode_external(panel_mode)

# ─── Panel signal handlers ────────────────────────────────────
func _on_panel_brush_changed(index: int) -> void:
	stroke_builder.current_brush_index = index
	# Sync size slider về đúng size của preset vừa chọn
	var preset := stroke_builder.get_current_preset()
	if preset:
		_brush_panel.sync_size_to(preset.brush_size)

func _on_panel_size_changed(value: float) -> void:
	# Ghi thẳng vào preset đang active của stroke_builder — không qua index
	var preset := stroke_builder.get_current_preset()
	if preset:
		preset.brush_size = value

func _on_panel_color_changed(color: Color) -> void:
	stroke_builder.current_color = color

func _on_panel_mode_changed(mode_val: int) -> void:
	if mode_val == 1:
		_set_mode(Mode.ERASE)
		stroke_builder.cancel_stroke()
		guide_drawer.cancel()
	else:
		_set_mode(Mode.DRAW)

# ─── Stroke flow ──────────────────────────────────────────────
func _start_stroke(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit := _raycast_plane(screen_pos)
	if hit == Vector3.INF:
		return
	stroke_builder.setup(camera, _active_plane.stroke_container, _active_plane)
	stroke_builder.start_stroke(hit)

func _continue_stroke(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit := _raycast_plane(screen_pos)
	if hit == Vector3.INF:
		return
	stroke_builder.add_point(hit)

func _finish_stroke() -> void:
	if not stroke_builder.is_drawing():
		return
	var data := stroke_builder.finish_stroke()
	if data and _active_plane:
		_active_plane.add_stroke(data)

# ─── Erase ────────────────────────────────────────────────────
func _do_erase(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit := _raycast_plane(screen_pos)
	if hit == Vector3.INF:
		return
	_active_plane.erase_at(hit, stroke_builder)

# ─── Raycast ──────────────────────────────────────────────────
func _raycast_plane(screen_pos: Vector2) -> Vector3:
	var space  := get_world_3d().direct_space_state
	var origin := camera.project_ray_origin(screen_pos)
	var dir    := camera.project_ray_normal(screen_pos)
	var query  := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	query.collision_mask  = 0xFFFFFFFF
	query.hit_back_faces  = true
	query.hit_from_inside = true

	var result := space.intersect_ray(query)
	if result.is_empty():
		return Vector3.INF

	var hit_body := result["collider"] as StaticBody3D
	if hit_body == null:
		return Vector3.INF

	var hit_plane := hit_body.get_parent() as DrawingPlane
	if hit_plane == null or hit_plane != _active_plane:
		return Vector3.INF

	return result["position"]

# ─── Guide finished ───────────────────────────────────────────
func _on_guide_finished(points_3d: Array) -> void:
	_preview_line.clear_points()

	var data := SurfaceGenerator.compute(points_3d, camera)
	if data.is_empty():
		return

	if _active_plane != null:
		if _active_plane.has_strokes:
			_active_plane.hide_grid()
			_active_plane.set_active(false)
		else:
			_active_plane.queue_free()
		_active_plane = null

	var plane: DrawingPlane = DrawingPlaneScene.instantiate()
	plane_container.add_child(plane)
	plane.global_position = data["center"]
	plane.initialize(data)
	_active_plane = plane
	_active_plane.set_active(true)

	await get_tree().physics_frame
	await get_tree().physics_frame

	if data["normal"] != Vector3.ZERO:
		camera.snap_to_plane(data["normal"])

# ─── Helpers ──────────────────────────────────────────────────
func _update_preview() -> void:
	_preview_line.clear_points()
	for p in guide_drawer.get_screen_points():
		_preview_line.add_point(p)

func _cancel_all() -> void:
	guide_drawer.cancel()
	stroke_builder.cancel_stroke()
	_preview_line.clear_points()
	_set_mode(Mode.DRAW)

func _reset_camera() -> void:
	camera._pivot    = Vector3.ZERO
	camera._distance = 8.0
	camera._yaw      = 30.0
	camera._pitch    = -20.0
	camera._apply_transform()
