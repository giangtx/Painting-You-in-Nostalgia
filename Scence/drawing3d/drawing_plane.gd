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
var _init_data:    Dictionary = {}  # lưu lại để duplicate

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
	_init_data = data.duplicate(true)  # lưu lại để duplicate sau

	match data["type"]:
		CurveDetector.Type.STRAIGHT:
			is_curved_surface = false      # [NEW]
			global_position = data["center"]
			global_basis    = Basis(data["right"], data["up"], -data["normal"])
			_build_background()
			_build_collision()

		CurveDetector.Type.CURVED:
			is_curved_surface = true
			# Đặt node tại center của surface — gizmo sẽ hiện đúng vị trí
			global_position = data["center"]
			# Build basis từ tangent + up của surface
			var tangent := (data["points"][-1] - data["points"][0]).normalized()
			if tangent.length() < 0.001:
				tangent = Vector3.RIGHT
			var up_dir  := (data["up"] as Vector3).normalized()
			var normal  := tangent.cross(up_dir).normalized()
			global_basis = Basis(tangent, up_dir, -normal)
			_build_surface_mesh(data["points"], data["up"], data["height"])

		CurveDetector.Type.CLOSED:
			is_curved_surface = true
			global_position = data["center"]
			var tangent := (data["points"][-1] - data["points"][0]).normalized()
			if tangent.length() < 0.001:
				tangent = Vector3.RIGHT
			var up_dir  := (data["up"] as Vector3).normalized()
			var normal  := tangent.cross(up_dir).normalized()
			global_basis = Basis(tangent, up_dir, -normal)
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

func get_init_data() -> Dictionary:
	# Cập nhật center/basis hiện tại vào data (vì gizmo có thể đã move/rotate plane)
	var data := _init_data.duplicate(true)
	data["center"] = global_position
	# Cập nhật lại các vector theo basis hiện tại cho STRAIGHT
	if not is_curved_surface:
		data["right"]  =  global_basis.x
		data["up"]     =  global_basis.y
		data["normal"] = -global_basis.z
	return data

func get_strokes_data() -> Array:
	return _strokes.duplicate()  # shallow copy của array, StrokeData objects vẫn shared

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
	var hh     := height * 0.5
	# Points đang là world space — convert sang local space của node này
	# (node đã được đặt tại global_position = center)
	var origin := global_position

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = COLOR_NORMAL

	var verts := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i] - origin
		var p1 : Vector3 = points[i + 1] - origin
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
		var p0 : Vector3 = points[i] - origin
		var p1 : Vector3 = points[i + 1] - origin
		im.surface_set_color(border_color)
		im.surface_add_vertex(p0 - up * hh)
		im.surface_add_vertex(p1 - up * hh)
		im.surface_set_color(border_color)
		im.surface_add_vertex(p0 + up * hh)
		im.surface_add_vertex(p1 + up * hh)
	im.surface_set_color(border_color)
	im.surface_add_vertex(points[0]  - origin - up * hh)
	im.surface_add_vertex(points[0]  - origin + up * hh)
	im.surface_add_vertex(points[-1] - origin - up * hh)
	im.surface_add_vertex(points[-1] - origin + up * hh)
	im.surface_end()
	_surface_border              = MeshInstance3D.new()
	_surface_border.mesh          = im
	_surface_border.material_override = bmat
	_surface_border.visible       = false
	add_child(_surface_border)

	# Collision faces — local space
	var faces := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i] - origin
		var p1 : Vector3 = points[i + 1] - origin
		faces.append_array([
			p0 - up*hh, p0 + up*hh, p1 + up*hh,
			p0 - up*hh, p1 + up*hh, p1 - up*hh
		])
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
	var body := get_node("Body") as StaticBody3D
	if body:
		if active:
			# Active plane: collision bật đầy đủ
			body.collision_layer = 1
			body.collision_mask  = 1
		else:
			# Inactive plane: tắt collision hoàn toàn
			# → raycast khi vẽ/erase không hit được
			# → chỉ bật lại tạm khi Ctrl giữ (gọi set_hoverable)
			body.collision_layer = 0
			body.collision_mask  = 0
	# CURVED/CLOSED: chỉ hiện surface mesh khi plane đang active
	if _surface_solid:
		_surface_solid.visible  = active
	if _surface_border:
		_surface_border.visible = active

# Bật/tắt collision tạm thời cho Ctrl+hover — không ảnh hưởng active state
func set_hoverable(enabled: bool) -> void:
	# Chỉ áp dụng cho inactive plane (active plane luôn có collision)
	var body := get_node("Body") as StaticBody3D
	if body and body.collision_layer == 0:
		body.collision_layer = 1 if enabled else 0
		body.collision_mask  = 1 if enabled else 0
