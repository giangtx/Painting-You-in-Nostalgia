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
var _strokes:      Array   = []

var has_strokes: bool:
	get: return _strokes.size() > 0

func initialize(data: Dictionary) -> void:
	plane_size = data["size"]

	match data["type"]:
		CurveDetector.Type.STRAIGHT:
			global_position = data["center"]
			global_basis    = Basis(data["right"], data["up"], -data["normal"])
			_build_background()
			_build_collision()

		CurveDetector.Type.CURVED:
			global_position = Vector3.ZERO
			_build_surface_mesh(data["points"], data["up"], data["height"])

		CurveDetector.Type.CLOSED:
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
	mat.albedo_color = background_color

	var quad  := QuadMesh.new()
	quad.size  = _display_size

	grid_mesh.mesh              = quad
	grid_mesh.material_override = mat

func _build_collision() -> void:
	var shape  := BoxShape3D.new()
	shape.size  = Vector3(plane_size.x, 50.0, 0.01)
	collision_shape.shape = shape

func add_stroke(stroke_mesh: MeshInstance3D) -> void:
	if stroke_mesh == null:
		return
	stroke_container.add_child(stroke_mesh)
	_strokes.append(stroke_mesh)

func _build_surface_mesh(points: Array, up: Vector3, height: float) -> void:
	var hh  := height * 0.5
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.4, 0.6, 1.0, 0.15)

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
	var mi_solid             := MeshInstance3D.new()
	mi_solid.mesh             = amesh
	mi_solid.material_override = mat
	add_child(mi_solid)

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
	var mi_border             := MeshInstance3D.new()
	mi_border.mesh             = im
	mi_border.material_override = bmat
	add_child(mi_border)

	var faces := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 : Vector3 = points[i]
		var p1 : Vector3 = points[i + 1]
		faces.append_array([
			p0 - up*hh, p0 + up*hh, p1 + up*hh,
			p0 - up*hh, p1 + up*hh, p1 - up*hh
		])
	var cshape := ConcavePolygonShape3D.new()
	cshape.set_faces(faces)
	collision_shape.shape = cshape

func hide_grid() -> void:
	grid_mesh.visible = false

func show_grid() -> void:
	grid_mesh.visible = true

func set_active(active: bool) -> void:
	var body := get_node("Body") as StaticBody3D
	if body:
		body.set_process_mode(
			Node.PROCESS_MODE_INHERIT if active
			else Node.PROCESS_MODE_DISABLED
		)
