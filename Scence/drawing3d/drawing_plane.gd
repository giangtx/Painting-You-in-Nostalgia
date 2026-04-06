# drawing_plane.gd
class_name DrawingPlane
extends Node3D

# ─── Cấu hình ─────────────────────────────────────────────────
@export var grid_color:   Color = Color(0.4, 0.6, 1.0, 0.25)
@export var border_color: Color = Color(0.4, 0.6, 1.0, 0.6)
@export var background_color: Color = Color(1.0, 1.0, 1.0, 0.08) 
# ─── Refs ─────────────────────────────────────────────────────
@onready var grid_mesh:        MeshInstance3D  = $GridMesh
@onready var collision_shape:  CollisionShape3D = $Body/Shape
@onready var stroke_container: Node3D           = $StrokeContainer

# ─── State ────────────────────────────────────────────────────
var plane_size:    Vector2     = Vector2.ZERO
var canvas:        PaintCanvas = null
var _paint_mesh:   MeshInstance3D = null
var _display_size: Vector2     = Vector2.ZERO

var has_strokes: bool:
	get: return canvas != null and canvas.has_strokes

# ─── Khởi tạo ────────────────────────────────────────────────
func initialize(data: Dictionary) -> void:
	plane_size = data["size"]

	match data["type"]:
		CurveDetector.Type.STRAIGHT:
			global_position = data["center"]
			global_basis    = Basis(data["right"], data["up"], -data["normal"])
			_build_grid()
			_build_collision()
			_setup_paint_canvas_flat()

		CurveDetector.Type.CURVED:
			global_position = Vector3.ZERO
			_build_surface_mesh(data["points"], data["up"], data["height"])

		CurveDetector.Type.CLOSED:
			global_position = Vector3.ZERO
			var closed = data["points"].duplicate()
			closed.append(data["points"][0])
			_build_surface_mesh(closed, data["up"], data["height"])

# ─── Setup paint canvas (chỉ cho STRAIGHT) ───────────────────
func _setup_paint_canvas_flat() -> void:
	_display_size = Vector2(plane_size.x, 50.0)
	canvas = PaintCanvas.new()
	add_child(canvas)
	canvas.setup(_display_size)

	# Mặt trước
	_paint_mesh      = MeshInstance3D.new()
	var quad         := QuadMesh.new()
	quad.size         = _display_size
	_paint_mesh.mesh  = quad
	var mat          := ShaderMaterial.new()
	mat.shader        = _create_paint_shader()
	mat.set_shader_parameter("paint_texture", canvas.img_texture)
	_paint_mesh.material_override = mat
	_paint_mesh.position          = Vector3(0, 0, 0.001)
	add_child(_paint_mesh)

	# Mặt sau
	var paint_mesh_back              := MeshInstance3D.new()
	var quad_back                    := QuadMesh.new()
	quad_back.size                    = _display_size
	paint_mesh_back.mesh              = quad_back
	var mat_back                     := ShaderMaterial.new()
	mat_back.shader                   = _create_paint_shader_back()
	mat_back.set_shader_parameter("paint_texture", canvas.img_texture)
	paint_mesh_back.material_override = mat_back
	paint_mesh_back.position          = Vector3(0, 0, -0.001)
	add_child(paint_mesh_back)

func _create_paint_shader() -> Shader:
	var s    := Shader.new()
	s.code    = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
uniform sampler2D paint_texture : source_color;
void fragment() {
	vec4 col = texture(paint_texture, UV);
	ALBEDO = col.rgb;
	ALPHA  = col.a;
}
"""
	return s

func _create_paint_shader_back() -> Shader:
	var s  := Shader.new()
	s.code  = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
uniform sampler2D paint_texture : source_color;
void fragment() {
    vec2 uv = vec2(UV.x, UV.y);
    vec4 col = texture(paint_texture, uv);
    ALBEDO = col.rgb;
    ALPHA  = col.a;
}
"""
	return s

# ─── Paint API ───────────────────────────────────────────────
func paint_at_world(world_point: Vector3) -> bool:
	if canvas == null:
		return false
	var local    := to_local(world_point)
	canvas.paint_at_local(Vector2(local.x, local.y), _display_size)
	return true

func paint_line_world(from_world: Vector3, to_world: Vector3) -> bool:
	if canvas == null:
		return false
	var from_l := to_local(from_world)
	var to_l   := to_local(to_world)
	canvas.paint_line(
		Vector2(from_l.x, from_l.y),
		Vector2(to_l.x,   to_l.y),
		_display_size
	)
	return true

# ─── Flat grid ───────────────────────────────────────────────
func _build_grid() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = background_color

	var quad  := QuadMesh.new()
	quad.size  = Vector2(plane_size.x, 50.0)

	grid_mesh.mesh              = quad
	grid_mesh.material_override = mat

func _build_collision() -> void:
	var shape  := BoxShape3D.new()
	shape.size  = Vector3(plane_size.x, 50.0, 0.1)
	collision_shape.shape = shape

# ─── Curved / Cylinder ───────────────────────────────────────
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

# ─── Visibility ───────────────────────────────────────────────
func hide_grid() -> void:
	grid_mesh.visible = false

func show_grid() -> void:
	grid_mesh.visible = true

func world_to_local_2d(world_point: Vector3) -> Vector2:
	var local := to_local(world_point)
	return Vector2(local.x, local.y)

func restore() -> void:
	if canvas == null or _paint_mesh == null:
		return
	# Re-apply texture vào shader sau khi visible lại
	(_paint_mesh.material_override as ShaderMaterial)\
		.set_shader_parameter("paint_texture", canvas.img_texture)
	visible = true

func set_active(active: bool) -> void:
	var body := get_node("Body") as StaticBody3D
	if body:
		body.set_process_mode(
			Node.PROCESS_MODE_INHERIT if active 
			else Node.PROCESS_MODE_DISABLED
		)
