# main.gd
extends Node3D

@onready var camera:          Camera3D       = $Camera
@onready var grid:            MeshInstance3D = $DrawingWorld/GridHelper
@onready var gizmo:           Control        = $GizmoContainer        # viewport gizmo XYZ
@onready var guide_drawer:    Node           = $GuideDrawer
@onready var plane_container: Node3D         = $DrawingWorld/PlaneContainer
@onready var stroke_builder:  StrokeBuilder  = $StrokeBuilder
@onready var _brush_panel                    = $CanvasLayer/BrushPanel

var _preview_canvas: CanvasLayer
var _preview_line:   Line2D

enum Mode { DRAW, GUIDE, ERASE }
var _mode: Mode = Mode.DRAW

var _active_plane:   DrawingPlane = null
var _hovered_plane:  DrawingPlane = null
var _last_mouse_pos: Vector2      = Vector2.ZERO
var _ctrl_was_held:  bool         = false

# ─── Plane Gizmo ──────────────────────────────────────────────
var _plane_gizmo: PlaneGizmo = null
var _alt_held:    bool       = false   # trạng thái Alt hiện tại

var _gizmo_just_attached: bool = false  # flag để detach gizmo khi user click lần đầu
const DrawingPlaneScene = preload("res://Scence/drawing3d/DrawingPlane.tscn")

# ─── Ready ────────────────────────────────────────────────────
func _ready() -> void:
	gizmo.setup(camera)
	_setup_preview_canvas()
	_setup_plane_gizmo()
	guide_drawer.setup(camera, _preview_canvas)
	guide_drawer.guide_finished.connect(_on_guide_finished)
	_setup_brush_panel()

func _process(_delta: float) -> void:
	# Ctrl+hover: bật collision cho inactive planes để raycast tìm được
	var ctrl_now := Input.is_key_pressed(KEY_CTRL)
	if ctrl_now != _ctrl_was_held:
		_ctrl_was_held = ctrl_now
		_set_inactive_planes_hoverable(ctrl_now)
		if not ctrl_now:
			_clear_hover_highlight()

	if ctrl_now:
		_update_hover_highlight(_last_mouse_pos)

	# Alt: toggle gizmo visibility
	var alt_now := Input.is_key_pressed(KEY_ALT)
	if alt_now != _alt_held:
		_alt_held = alt_now
		if _plane_gizmo:
			if alt_now and _active_plane != null:
				_plane_gizmo.attach(_active_plane)
			else:
				_plane_gizmo.detach()

func _setup_preview_canvas() -> void:
	_preview_canvas             = CanvasLayer.new()
	add_child(_preview_canvas)
	_preview_line               = Line2D.new()
	_preview_line.width         = 2.0
	_preview_line.default_color = Color(1.0, 0.85, 0.2, 0.9)
	_preview_line.antialiased   = true
	_preview_canvas.add_child(_preview_line)

func _setup_plane_gizmo() -> void:
	_plane_gizmo = PlaneGizmo.new()
	add_child(_plane_gizmo)
	_plane_gizmo.setup(camera)
	_plane_gizmo.transform_changed.connect(_on_plane_gizmo_transform_changed)

func _setup_brush_panel() -> void:
	var init_size := stroke_builder.get_current_preset().brush_size \
					 if stroke_builder.get_current_preset() else 0.08
	_brush_panel.setup(stroke_builder.brushes, stroke_builder.current_color, init_size)
	_brush_panel.brush_changed.connect(_on_panel_brush_changed)
	_brush_panel.brush_size_changed.connect(_on_panel_size_changed)
	_brush_panel.color_changed.connect(_on_panel_color_changed)
	_brush_panel.mode_changed.connect(_on_panel_mode_changed)
	_brush_panel.brush_opacity_changed.connect(_on_panel_opacity_changed)
	_brush_panel.brush_thickness_changed.connect(_on_panel_thickness_changed)

# ─── Input ────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_G:      grid.toggle()
			KEY_F:      _focus_active_plane()
			KEY_D:      _duplicate_active_plane()
			KEY_HOME:   _reset_camera()
			KEY_ESCAPE: _cancel_all()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var shift_held := Input.is_key_pressed(KEY_SHIFT)
		var ctrl_held  := Input.is_key_pressed(KEY_CTRL)
		var e_held     := Input.is_key_pressed(KEY_E)

		if event.pressed:
			# Gizmo visible → thử start drag trước (Alt giữ hoặc sau duplicate)
			if _plane_gizmo and _plane_gizmo.visible:
				if _plane_gizmo.start_drag(event.position):
					return  # gizmo ăn input, không vẽ

			# Ctrl+click → switch active plane
			if ctrl_held:
				if _hovered_plane != null:
					_switch_active_plane(_hovered_plane)
				return

			# Gizmo vừa attach sau duplicate → click đầu tiên detach gizmo
			if _gizmo_just_attached:
				_gizmo_just_attached = false
				if _plane_gizmo:
					_plane_gizmo.detach()
				# Không return — tiếp tục xử lý input bình thường

			if e_held:
				_set_mode(Mode.ERASE)
				stroke_builder.cancel_stroke()
				guide_drawer.cancel()
			elif shift_held:
				_set_mode(Mode.GUIDE)
				stroke_builder.cancel_stroke()
				guide_drawer.start_guide(event.position)
			elif _mode == Mode.ERASE:
				pass
			else:
				_set_mode(Mode.DRAW)
				_start_stroke(event.position)
		else:  # released
			# Kết thúc gizmo drag
			if _plane_gizmo and _plane_gizmo.is_dragging():
				_plane_gizmo.end_drag()
				return

			if _mode == Mode.GUIDE:
				guide_drawer.finish_guide()
				_set_mode(Mode.DRAW)
			elif _mode == Mode.DRAW:
				_finish_stroke()

	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position

		# Gizmo drag update — ưu tiên trước mọi thứ
		if _plane_gizmo and _plane_gizmo.is_dragging():
			_plane_gizmo.update_drag(event.position)
			return

		# Gizmo hover update khi gizmo đang visible (Alt giữ hoặc sau duplicate)
		if _plane_gizmo and _plane_gizmo.visible:
			_plane_gizmo.update_hover(event.position)
			# Không return — vẫn cho các event khác chạy nếu không hover vào handle

		if _mode == Mode.GUIDE:
			guide_drawer.add_point(event.position)
			_update_preview()
		elif _mode == Mode.DRAW and stroke_builder.is_drawing():
			_continue_stroke(event.position)
		elif _mode == Mode.ERASE and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_do_erase(event.position)

# ─── Gizmo transform changed ──────────────────────────────────
func _on_plane_gizmo_transform_changed() -> void:
	pass  # camera không follow khi gizmo transform

# ─── Đồng bộ mode ─────────────────────────────────────────────
func _set_mode(m: Mode) -> void:
	_mode = m
	if _brush_panel:
		var panel_mode := 1 if m == Mode.ERASE else 0
		_brush_panel.set_mode_external(panel_mode)

# ─── Panel signal handlers ────────────────────────────────────
func _on_panel_brush_changed(index: int) -> void:
	stroke_builder.current_brush_index = index
	var preset := stroke_builder.get_current_preset()
	if preset:
		_brush_panel.sync_size_to(preset.brush_size)
		_brush_panel.sync_opacity_to(preset.opacity)
		_brush_panel.sync_thickness_to(preset.thickness)

func _on_panel_size_changed(value: float) -> void:
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

func _on_panel_opacity_changed(value: float) -> void:
	var preset := stroke_builder.get_current_preset()
	if preset:
		preset.opacity = value

func _on_panel_thickness_changed(value: float) -> void:
	var preset := stroke_builder.get_current_preset()
	if preset:
		preset.thickness = value

# ─── Stroke flow ──────────────────────────────────────────────
func _start_stroke(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit_data := _raycast_plane(screen_pos)
	if hit_data.is_empty():
		return
	stroke_builder.setup(camera, _active_plane.stroke_container, _active_plane)
	stroke_builder.start_stroke(hit_data["position"], hit_data["normal"])

func _continue_stroke(screen_pos: Vector2) -> void:
	if _active_plane == null:
		return
	var hit_data := _raycast_plane(screen_pos)
	if hit_data.is_empty():
		return
	stroke_builder.add_point(hit_data["position"], hit_data["normal"])

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
	var hit_data := _raycast_plane(screen_pos)
	if hit_data.is_empty():
		return
	_active_plane.erase_at(hit_data["position"], stroke_builder)

# ─── Raycast chỉ vào active plane ────────────────────────────
func _raycast_plane(screen_pos: Vector2) -> Dictionary:
	var space  := get_world_3d().direct_space_state
	var origin := camera.project_ray_origin(screen_pos)
	var dir    := camera.project_ray_normal(screen_pos)
	var query  := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	query.collision_mask  = 0xFFFFFFFF
	query.hit_back_faces  = true
	query.hit_from_inside = true

	var result := space.intersect_ray(query)
	if result.is_empty():
		return {}

	var hit_body := result["collider"] as StaticBody3D
	if hit_body == null:
		return {}

	var hit_plane := hit_body.get_parent() as DrawingPlane
	if hit_plane == null or hit_plane != _active_plane:
		return {}

	return {
		"position": result["position"],
		"normal":   result["normal"],
	}

# ─── Raycast bất kỳ plane nào (trừ excluded) ─────────────────
func _raycast_any_plane(screen_pos: Vector2, excluded: DrawingPlane) -> DrawingPlane:
	var space  := get_world_3d().direct_space_state
	var origin := camera.project_ray_origin(screen_pos)
	var dir    := camera.project_ray_normal(screen_pos)
	var query  := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	query.collision_mask  = 0xFFFFFFFF
	query.hit_back_faces  = true
	query.hit_from_inside = true

	var exclude_rids: Array[RID] = []
	if excluded != null:
		var body := excluded.get_node_or_null("Body") as StaticBody3D
		if body:
			exclude_rids.append(body.get_rid())
	query.exclude = exclude_rids

	var result := space.intersect_ray(query)
	if result.is_empty():
		return null

	var hit_body := result["collider"] as StaticBody3D
	if hit_body == null:
		return null

	return hit_body.get_parent() as DrawingPlane

func _set_inactive_planes_hoverable(enabled: bool) -> void:
	for child in plane_container.get_children():
		var plane := child as DrawingPlane
		if plane != null and plane != _active_plane:
			plane.set_hoverable(enabled)

# ─── Ctrl hover highlight ─────────────────────────────────────
func _update_hover_highlight(screen_pos: Vector2) -> void:
	var hit_plane := _raycast_any_plane(screen_pos, _active_plane)

	if hit_plane == _hovered_plane:
		return

	_clear_hover_highlight()

	if hit_plane != null:
		_hovered_plane = hit_plane
		_hovered_plane.set_highlighted(true)

func _clear_hover_highlight() -> void:
	if _hovered_plane != null:
		_hovered_plane.set_highlighted(false)
		_hovered_plane = null

# ─── Switch active plane ──────────────────────────────────────
func _switch_active_plane(new_plane: DrawingPlane) -> void:
	if new_plane == _active_plane:
		return

	_clear_hover_highlight()

	# Ẩn gizmo nếu đang hiện
	if _plane_gizmo:
		_plane_gizmo.detach()

	if _active_plane != null:
		_active_plane.hide_grid()
		_active_plane.set_active(false)
		camera.active_plane = null
		_active_plane = null

	_active_plane = new_plane
	_active_plane.set_active(true)

	# Pivot camera snap về điểm gần nhất trên plane mới
	_snap_camera_pivot_to_plane(_active_plane)

	# Neo camera theo plane mới
	camera.active_plane = _active_plane

	# Snap hướng camera nhìn vào plane
	var plane_normal := -_active_plane.global_basis.z
	if _active_plane.is_curved_surface:
		plane_normal = Vector3.ZERO  # CURVED không có normal cố định, bỏ snap
	if plane_normal != Vector3.ZERO:
		camera.snap_to_plane(plane_normal)

	# Nếu Alt đang giữ → hiện gizmo luôn
	if _alt_held and _plane_gizmo:
		_plane_gizmo.attach(_active_plane)

	await get_tree().physics_frame
	await get_tree().physics_frame

# ─── Snap camera pivot về center của plane (mượt) ────────────
func _snap_camera_pivot_to_plane(plane: DrawingPlane) -> void:
	if plane == null:
		return
	var target_pivot    := plane.global_position
	var current_dist    := camera.global_position.distance_to(target_pivot)
	var target_distance := clampf(current_dist, 3.0, 15.0)
	# Dùng focus_on để animate mượt — không giật
	# plane_normal = ZERO → giữ nguyên góc nhìn hiện tại
	camera.focus_on(target_pivot, target_distance, Vector3.ZERO)

# ─── Guide finished ───────────────────────────────────────────
func _on_guide_finished(points_3d: Array) -> void:
	_preview_line.clear_points()
	_clear_hover_highlight()

	var data := SurfaceGenerator.compute(points_3d, camera)
	if data.is_empty():
		return

	# Ẩn gizmo trước khi thay plane
	if _plane_gizmo:
		_plane_gizmo.detach()

	if _active_plane != null:
		if _active_plane.has_strokes:
			_active_plane.hide_grid()
			_active_plane.set_active(false)
		else:
			_active_plane.queue_free()
		camera.active_plane = null
		_active_plane = null

	var plane: DrawingPlane = DrawingPlaneScene.instantiate()
	plane_container.add_child(plane)
	plane.global_position = data["center"]
	plane.initialize(data)
	_active_plane = plane
	_active_plane.set_active(true)

	# Pivot snap và neo camera
	_snap_camera_pivot_to_plane(_active_plane)
	camera.active_plane = _active_plane

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
	_clear_hover_highlight()
	if _plane_gizmo:
		_plane_gizmo.end_drag()
	_set_mode(Mode.DRAW)

func _focus_active_plane() -> void:
	if _active_plane == null:
		return
	var target_pivot    := _active_plane.global_position
	var current_dist    := camera.global_position.distance_to(target_pivot)
	var target_distance := clampf(current_dist, 3.0, 15.0)
	var plane_normal    := Vector3.ZERO
	if not _active_plane.is_curved_surface:
		plane_normal = -_active_plane.global_basis.z
	camera.focus_on(target_pivot, target_distance, plane_normal)

# ─── Duplicate active plane ───────────────────────────────────
func _duplicate_active_plane() -> void:
	if _active_plane == null:
		return

	var src_plane := _active_plane
	var init_data := src_plane.get_init_data()
	var strokes   := src_plane.get_strokes_data()

	# Deactivate plane cũ
	src_plane.hide_grid()
	src_plane.set_active(false)
	camera.active_plane = null

	# Tạo plane mới tại cùng vị trí
	var new_plane: DrawingPlane = DrawingPlaneScene.instantiate()
	plane_container.add_child(new_plane)
	new_plane.global_position = src_plane.global_position
	new_plane.initialize(init_data)

	# Copy strokes: rebuild mesh từ StrokeData trên parent mới
	stroke_builder.setup(camera, new_plane.stroke_container, new_plane)
	for stroke_data in strokes:
		var sd := stroke_data as StrokeBuilder.StrokeData
		if sd == null or sd.stamp_positions.is_empty():
			continue
		# Rebuild mesh từ stamp data đã có — dùng _build_mesh_from_stamps_local
		var mi := stroke_builder._build_mesh_from_stamps_local(
			sd.stamp_positions,
			sd.stamp_normals,
			sd.is_surface_normal,
			sd.preset,
			sd.rng_seed,
			sd.color,
			sd.brush_size,
			sd.thickness,
			sd.opacity
		)
		if mi:
			if mi.material_override:
				mi.material_override.render_priority = sd.render_order
			# Tạo StrokeData mới cho plane mới
			var new_sd                := StrokeBuilder.StrokeData.new()
			new_sd.mesh_inst           = mi
			new_sd.stamp_positions     = sd.stamp_positions.duplicate()
			new_sd.stamp_normals       = sd.stamp_normals.duplicate()
			new_sd.is_surface_normal   = sd.is_surface_normal
			new_sd.rng_seed            = sd.rng_seed
			new_sd.preset              = sd.preset
			new_sd.brush_size          = sd.brush_size
			new_sd.thickness           = sd.thickness
			new_sd.opacity             = sd.opacity
			new_sd.spacing             = sd.spacing
			new_sd.color               = sd.color
			new_sd.plane_right         = sd.plane_right
			new_sd.plane_up            = sd.plane_up
			new_sd.plane_normal        = sd.plane_normal
			new_sd.render_order        = sd.render_order
			new_plane.add_stroke(new_sd)

	# Activate plane mới
	_active_plane = new_plane
	_active_plane.set_active(true)
	camera.active_plane = _active_plane

	# Attach gizmo ngay để user biết plane mới đang ở đâu
	if _plane_gizmo:
		_plane_gizmo.attach(_active_plane)
		_gizmo_just_attached = true

	await get_tree().physics_frame
	await get_tree().physics_frame

func _reset_camera() -> void:
	camera._pivot    = Vector3.ZERO
	camera._distance = 8.0
	camera._yaw      = 30.0
	camera._pitch    = -20.0
	camera._apply_transform()
