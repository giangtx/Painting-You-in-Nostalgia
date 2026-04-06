# main.gd
extends Node3D

@onready var camera:          Camera3D       = $Camera
@onready var grid:            MeshInstance3D = $DrawingWorld/GridHelper
@onready var gizmo:           Control        = $GizmoContainer
@onready var guide_drawer:    Node           = $GuideDrawer
@onready var plane_container: Node3D         = $DrawingWorld/PlaneContainer

var _preview_canvas: CanvasLayer
var _preview_line:   Line2D

enum Mode { DRAW, GUIDE }
var _mode: Mode = Mode.DRAW

var _active_plane:   DrawingPlane  = null
var _stroke_builder: StrokeBuilder = null

const DrawingPlaneScene = preload("res://Scence/drawing3d/DrawingPlane.tscn")

func _ready() -> void:
	gizmo.setup(camera)
	_setup_preview_canvas()
	guide_drawer.setup(camera, _preview_canvas)
	guide_drawer.guide_finished.connect(_on_guide_finished)

	_stroke_builder = StrokeBuilder.new()
	add_child(_stroke_builder)

func _setup_preview_canvas() -> void:
	_preview_canvas             = CanvasLayer.new()
	add_child(_preview_canvas)
	_preview_line               = Line2D.new()
	_preview_line.width         = 2.0
	_preview_line.default_color = Color(1.0, 0.85, 0.2, 0.9)
	_preview_line.antialiased   = true
	_preview_canvas.add_child(_preview_line)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_G:      grid.toggle()
			KEY_F:      _reset_camera()
			KEY_ESCAPE: _cancel_all()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var shift_held := Input.is_key_pressed(KEY_SHIFT)

		if event.pressed:
			if shift_held:
				_mode = Mode.GUIDE
				_stroke_builder.cancel_stroke()
				guide_drawer.start_guide(event.position)
			else:
				_mode = Mode.DRAW
				_start_stroke(event.position)
		else:
			if _mode == Mode.GUIDE:
				guide_drawer.finish_guide()
				_mode = Mode.DRAW
			elif _mode == Mode.DRAW:
				_finish_stroke()

	if event is InputEventMouseMotion:
		if _mode == Mode.GUIDE:
			guide_drawer.add_point(event.position)
			_update_preview()
		elif _mode == Mode.DRAW and _stroke_builder.is_drawing():
			_continue_stroke(event.position)

# ─── Stroke flow ──────────────────────────────────────────────
func _start_stroke(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit := _raycast_plane(screen_pos)
	if hit == Vector3.INF:
		print("no hit")
		return
	print("hit world: ", hit)
	print("plane global_pos: ", _active_plane.global_position)
	print("plane basis: ", _active_plane.global_basis)
	_stroke_builder.setup(camera, _active_plane.stroke_container)
	_stroke_builder.start_stroke(hit)

func _continue_stroke(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit := _raycast_plane(screen_pos)
	if hit == Vector3.INF:
		return
	_stroke_builder.add_point(hit)

func _finish_stroke() -> void:
	if not _stroke_builder.is_drawing():
		return
	var stroke_mesh := _stroke_builder.finish_stroke()
	if stroke_mesh and _active_plane:
		_active_plane.add_stroke(stroke_mesh)

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
	_stroke_builder.cancel_stroke()
	_preview_line.clear_points()
	_mode = Mode.DRAW

func _reset_camera() -> void:
	camera._pivot    = Vector3.ZERO
	camera._distance = 8.0
	camera._yaw      = 30.0
	camera._pitch    = -20.0
	camera._apply_transform()
