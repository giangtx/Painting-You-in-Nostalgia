# drawing_plane.gd
class_name DrawingPlane
extends Node3D

@export var background_color: Color = Color(1.0, 1.0, 1.0, 0.08)
@export var border_color:     Color = Color(0.4, 0.6, 1.0, 0.6)

@onready var grid_mesh:        MeshInstance3D   = $GridMesh
@onready var collision_shape:  CollisionShape3D = $Body/Shape
@onready var stroke_container: Node3D           = $StrokeContainer

var plane_size:    Vector2    = Vector2.ZERO
var _display_size: Vector2    = Vector2.ZERO
var _strokes:      Array      = []        # Array[StrokeBuilder.StrokeData]
var _init_data:    Dictionary = {}

var is_curved_surface: bool = false

var _surface_solid:  MeshInstance3D = null
var _surface_border: MeshInstance3D = null

const COLOR_NORMAL         := Color(0.4, 0.6, 1.0, 0.255)
const COLOR_HIGHLIGHT      := Color(0.9, 0.75, 0.2, 0.45)
const GRID_COLOR_NORMAL    := Color(0.4, 0.6, 1.0, 0.255)
const GRID_COLOR_HIGHLIGHT := Color(0.9, 0.75, 0.2, 0.35)

var has_strokes: bool:
	get: return _strokes.size() > 0

# ─── Initialize ───────────────────────────────────────────────────
func initialize(data: Dictionary) -> void:
	plane_size = data["size"]
	_init_data = data.duplicate(true)

	match data["type"]:
		CurveDetector.Type.STRAIGHT:
			is_curved_surface = false
			global_position   = data["center"]
			global_basis      = Basis(data["right"], data["up"], -data["normal"])
			_build_background()
			_build_collision()

		CurveDetector.Type.CURVED:
			is_curved_surface = true
			global_position   = data["center"]
			var tangent = (data["points"][-1] - data["points"][0]).normalized()
			if tangent.length() < 0.001: tangent = Vector3.RIGHT
			var up_dir := (data["up"] as Vector3).normalized()
			var normal  = tangent.cross(up_dir).normalized()
			global_basis = Basis(tangent, up_dir, -normal)
			_build_surface_mesh(data["points"], data["up"], data["height"])

		CurveDetector.Type.CLOSED:
			is_curved_surface = true
			global_position   = data["center"]
			var tangent = (data["points"][-1] - data["points"][0]).normalized()
			if tangent.length() < 0.001: tangent = Vector3.RIGHT
			var up_dir := (data["up"] as Vector3).normalized()
			var normal  = tangent.cross(up_dir).normalized()
			global_basis = Basis(tangent, up_dir, -normal)
			var closed = data["points"].duplicate()
			closed.append(data["points"][0])
			_build_surface_mesh(closed, data["up"], data["height"])

func _build_background() -> void:
	_display_size = Vector2(plane_size.x, 50.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode       = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color    = GRID_COLOR_NORMAL
	mat.render_priority = -10
	var quad := QuadMesh.new()
	quad.size            = _display_size
	grid_mesh.mesh              = quad
	grid_mesh.material_override = mat

func _build_collision() -> void:
	var shape := BoxShape3D.new()
	shape.size            = Vector3(plane_size.x, 50.0, 0.01)
	collision_shape.shape = shape

# ─── Stroke management ────────────────────────────────────────────
func get_init_data() -> Dictionary:
	var data := _init_data.duplicate(true)
	data["center"] = global_position
	if not is_curved_surface:
		data["right"]  =  global_basis.x
		data["up"]     =  global_basis.y
		data["normal"] = -global_basis.z
	return data

func get_strokes_data() -> Array:
	return _strokes.duplicate()

func add_stroke(data: StrokeBuilder.StrokeData, _stroke_builder: StrokeBuilder = null) -> void:
	if data == null or data.mesh_inst == null:
		return
	var priority := clampi(_strokes.size(), -127, 127)
	data.render_order = priority
	_apply_depth_offset(data.mesh_inst, priority)
	stroke_container.add_child(data.mesh_inst)
	_strokes.append(data)

func erase_at(world_point: Vector3, stroke_builder: StrokeBuilder) -> void:
	var preset = stroke_builder.get_current_preset()
	var radius = (preset.size_u() if preset else 0.1) * 0.5

	var new_strokes := stroke_builder.erase_at(world_point, _strokes, radius)

	# Loại stroke bị xoá hết
	_strokes = _strokes.filter(func(d): return not (d as StrokeBuilder.StrokeData).points.is_empty())

	# Thêm các đoạn mới từ split
	for sd in new_strokes:
		stroke_container.add_child(sd.mesh_inst)
		_strokes.append(sd)

	# Reorder toàn bộ
	for i in _strokes.size():
		var sd := _strokes[i] as StrokeBuilder.StrokeData
		if sd == null or sd.mesh_inst == null: continue
		var priority := clampi(i, -127, 127)
		sd.render_order = priority
		_apply_depth_offset(sd.mesh_inst, priority)

func _apply_depth_offset(mi: MeshInstance3D, priority: int) -> void:
	var depth_off := -float(priority) * 0.01
	for i in mi.get_surface_override_material_count():
		var mat := mi.get_surface_override_material(i)
		if mat:
			mat.render_priority = priority
			if mat is ShaderMaterial:
				(mat as ShaderMaterial).set_shader_parameter("depth_offset", depth_off)

# ─── Surface mesh (CURVED / CLOSED) ──────────────────────────────
func _build_surface_mesh(points: Array, up: Vector3, height: float) -> void:
	var hh     := height * 0.5
	var origin := global_position

	var mat := StandardMaterial3D.new()
	mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode       = BaseMaterial3D.CULL_DISABLED
	mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color    = COLOR_NORMAL
	mat.render_priority = -10

	var verts := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]     - origin
		var p1 : Vector3 = points[i + 1] - origin
		var b0 := p0 - up * hh; var t0 := p0 + up * hh
		var b1 := p1 - up * hh; var t1 := p1 + up * hh
		verts.append(b0); verts.append(t0); verts.append(t1)
		verts.append(b0); verts.append(t1); verts.append(b1)

	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_surface_solid                   = MeshInstance3D.new()
	_surface_solid.mesh               = amesh
	_surface_solid.material_override  = mat
	_surface_solid.visible            = false
	add_child(_surface_solid)

	var bmat := StandardMaterial3D.new()
	bmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.vertex_color_use_as_albedo = true
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]     - origin
		var p1 : Vector3 = points[i + 1] - origin
		im.surface_set_color(border_color)
		im.surface_add_vertex(p0 - up * hh); im.surface_add_vertex(p1 - up * hh)
		im.surface_set_color(border_color)
		im.surface_add_vertex(p0 + up * hh); im.surface_add_vertex(p1 + up * hh)
	im.surface_set_color(border_color)
	im.surface_add_vertex(points[0]  - origin - up * hh)
	im.surface_add_vertex(points[0]  - origin + up * hh)
	im.surface_add_vertex(points[-1] - origin - up * hh)
	im.surface_add_vertex(points[-1] - origin + up * hh)
	im.surface_end()
	_surface_border                   = MeshInstance3D.new()
	_surface_border.mesh               = im
	_surface_border.material_override  = bmat
	_surface_border.visible            = false
	add_child(_surface_border)

	var faces := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]     - origin
		var p1 : Vector3 = points[i + 1] - origin
		faces.append_array([p0-up*hh, p0+up*hh, p1+up*hh, p0-up*hh, p1+up*hh, p1-up*hh])
		faces.append_array([p1+up*hh, p0+up*hh, p0-up*hh, p1-up*hh, p1+up*hh, p0-up*hh])
	var cshape := ConcavePolygonShape3D.new()
	cshape.set_faces(faces)
	collision_shape.shape = cshape

# ─── Highlight / active state ─────────────────────────────────────
var _grid_was_visible: bool = true

func set_highlighted(on: bool) -> void:
	if _surface_solid and _surface_solid.material_override:
		var mat := _surface_solid.material_override as StandardMaterial3D
		if mat: mat.albedo_color = COLOR_HIGHLIGHT if on else COLOR_NORMAL
	elif grid_mesh and grid_mesh.material_override:
		var mat := grid_mesh.material_override as StandardMaterial3D
		if mat:
			if on:
				_grid_was_visible    = grid_mesh.visible
				grid_mesh.visible    = true
				mat.albedo_color     = GRID_COLOR_HIGHLIGHT
			else:
				mat.albedo_color  = GRID_COLOR_NORMAL
				grid_mesh.visible = _grid_was_visible

func hide_grid() -> void: grid_mesh.visible = false
func show_grid() -> void: grid_mesh.visible = true

func set_active(active: bool) -> void:
	var body := get_node("Body") as StaticBody3D
	if body:
		body.collision_layer = 1 if active else 0
		body.collision_mask  = 1 if active else 0
	if _surface_solid:  _surface_solid.visible  = active
	if _surface_border: _surface_border.visible = active

func set_hoverable(enabled: bool) -> void:
	var body := get_node("Body") as StaticBody3D
	if body and body.collision_layer == 0:
		body.collision_layer = 1 if enabled else 0
		body.collision_mask  = 1 if enabled else 0
