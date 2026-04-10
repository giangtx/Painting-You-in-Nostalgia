# drawing_plane.gd
class_name DrawingPlane
extends Node3D

@export var background_color: Color = Color(1.0, 1.0, 1.0, 0.08)
@export var border_color:     Color = Color(0.4, 0.6, 1.0, 0.6)

@onready var grid_mesh:        MeshInstance3D  = $GridMesh
@onready var collision_shape:  CollisionShape3D = $Body/Shape
@onready var stroke_container: Node3D           = $StrokeContainer

var plane_size:    Vector2 = Vector2.ZERO
var _display_size: Vector2 = Vector2.ZERO
var _strokes:      Array   = []   # Array[StrokeBuilder.StrokeData]

# Flag để stroke_builder biết cần dùng per-stamp normal
var is_curved_surface: bool = false

# Reference tới 2 mesh visual của CURVED/CLOSED — toggle theo active state
var _surface_solid:  MeshInstance3D = null
var _surface_border: MeshInstance3D = null

# Màu bình thường và màu highlight
const COLOR_NORMAL    := Color(0.4, 0.6, 1.0, 0.15)
const COLOR_HIGHLIGHT := Color(0.9, 0.75, 0.2, 0.45)
const GRID_COLOR_NORMAL    := Color(1.0, 1.0, 1.0, 0.08)
const GRID_COLOR_HIGHLIGHT := Color(0.9, 0.75, 0.2, 0.35)

var has_strokes: bool:
	get: return _strokes.size() > 0

func initialize(data: Dictionary) -> void:
	plane_size = data["size"]

	match data["type"]:
		CurveDetector.Type.STRAIGHT:
			is_curved_surface = false      # [NEW]
			global_position = data["center"]
			global_basis    = Basis(data["right"], data["up"], -data["normal"])
			_build_background()
			_build_collision()

		CurveDetector.Type.CURVED:
			is_curved_surface = true       # [NEW]
			global_position = Vector3.ZERO
			_build_surface_mesh(data["points"], data["up"], data["height"])

		CurveDetector.Type.CLOSED:
			is_curved_surface = true       # [NEW]
			global_position = Vector3.ZERO
			var closed = data["points"].duplicate()
			closed.append(data["points"][0])
			_build_surface_mesh(closed, data["up"], data["height"])

func _build_background() -> void:
	_display_size = Vector2(plane_size.x, 50.0)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = GRID_COLOR_NORMAL

	var quad  := QuadMesh.new()
	quad.size  = _display_size

	grid_mesh.mesh              = quad
	grid_mesh.material_override = mat

func _build_collision() -> void:
	var shape  := BoxShape3D.new()
	shape.size  = Vector3(plane_size.x, 50.0, 0.01)
	collision_shape.shape = shape

func add_stroke(data: StrokeBuilder.StrokeData) -> void:
	if data == null or data.mesh_inst == null:
		return
	stroke_container.add_child(data.mesh_inst)
	_strokes.append(data)

func erase_at(world_point: Vector3, stroke_builder: StrokeBuilder) -> void:
	var preset  := stroke_builder.get_current_preset()
	var radius  := (preset.brush_size if preset else 0.08) * 0.5
	stroke_builder.erase_at(world_point, _strokes, radius)
	_strokes = _strokes.filter(func(d): return not d.stamp_positions.is_empty())

func _build_surface_mesh(points: Array, up: Vector3, height: float) -> void:
	var hh  := height * 0.5
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = COLOR_NORMAL

	var verts := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]
		var p1 : Vector3 = points[i + 1]
		var b0 := p0 - up * hh
		var t0 := p0 + up * hh
		var b1 := p1 - up * hh
		var t1 := p1 + up * hh
		verts.append(b0); verts.append(t0); verts.append(t1)
		verts.append(b0); verts.append(t1); verts.append(b1)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_surface_solid              = MeshInstance3D.new()
	_surface_solid.mesh          = amesh
	_surface_solid.material_override = mat
	_surface_solid.visible       = false   # ẩn cho đến khi set_active(true)
	add_child(_surface_solid)

	var bmat := StandardMaterial3D.new()
	bmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.vertex_color_use_as_albedo = true
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]
		var p1 : Vector3 = points[i + 1]
		im.surface_set_color(border_color)
		im.surface_add_vertex(p0 - up * hh)
		im.surface_add_vertex(p1 - up * hh)
		im.surface_set_color(border_color)
		im.surface_add_vertex(p0 + up * hh)
		im.surface_add_vertex(p1 + up * hh)
	im.surface_set_color(border_color)
	im.surface_add_vertex(points[0]  - up * hh)
	im.surface_add_vertex(points[0]  + up * hh)
	im.surface_add_vertex(points[-1] - up * hh)
	im.surface_add_vertex(points[-1] + up * hh)
	im.surface_end()
	_surface_border              = MeshInstance3D.new()
	_surface_border.mesh          = im
	_surface_border.material_override = bmat
	_surface_border.visible       = false   # ẩn cho đến khi set_active(true)
	add_child(_surface_border)

	# ── [CHANGED] Collision: 2 lớp face (mặt trước + mặt sau) để hit_back_faces
	# và hit_from_inside đều có normal chính xác từ cả hai phía ──────────────
	#
	# ConcavePolygonShape3D trong Godot 4 đã hỗ trợ backface hits khi
	# PhysicsRayQueryParameters3D.hit_back_faces = true, nhưng normal trả về
	# sẽ là normal của face gốc (không flip). Để nhận normal đúng hướng từ
	# cả hai phía, ta thêm các face đảo chiều (winding ngược) vào cùng shape.
	var faces := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]
		var p1 : Vector3 = points[i + 1]
		# Mặt gốc (winding thuận)
		faces.append_array([
			p0 - up*hh, p0 + up*hh, p1 + up*hh,
			p0 - up*hh, p1 + up*hh, p1 - up*hh
		])
		# [NEW] Mặt đảo chiều — normal ngược lại → vẽ được từ phía sau
		faces.append_array([
			p1 + up*hh, p0 + up*hh, p0 - up*hh,
			p1 - up*hh, p1 + up*hh, p0 - up*hh
		])

	var cshape := ConcavePolygonShape3D.new()
	cshape.set_faces(faces)
	collision_shape.shape = cshape

# Lưu trạng thái visible của grid_mesh trước khi highlight — để restore đúng khi bỏ highlight
var _grid_was_visible: bool = true

func set_highlighted(on: bool) -> void:
	# CURVED/CLOSED — đổi màu surface solid
	if _surface_solid and _surface_solid.material_override:
		var mat := _surface_solid.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = COLOR_HIGHLIGHT if on else COLOR_NORMAL
	# STRAIGHT — đổi màu grid_mesh, tạm show nếu đang ẩn
	elif grid_mesh and grid_mesh.material_override:
		var mat := grid_mesh.material_override as StandardMaterial3D
		if mat:
			if on:
				_grid_was_visible = grid_mesh.visible  # lưu trạng thái trước
				grid_mesh.visible    = true
				mat.albedo_color     = GRID_COLOR_HIGHLIGHT
			else:
				mat.albedo_color  = GRID_COLOR_NORMAL
				grid_mesh.visible = _grid_was_visible  # restore lại

func hide_grid() -> void:
	grid_mesh.visible = false

func show_grid() -> void:
	grid_mesh.visible = true

func set_active(active: bool) -> void:
	# Dùng flag thay vì disable physics hoàn toàn
	# → inactive plane vẫn có collision để raycast hover hit được
	# → main.gd tự lọc theo _active_plane khi vẽ/erase
	var body := get_node("Body") as StaticBody3D
	if body:
		# Chỉ disable input processing, KHÔNG disable physics/collision
		body.input_ray_pickable = false if not active else true
	# CURVED/CLOSED: chỉ hiện surface mesh khi plane đang active
	if _surface_solid:
		_surface_solid.visible  = active
	if _surface_border:
		_surface_border.visible = active
