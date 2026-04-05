# drawing_plane.gd
class_name DrawingPlane
extends Node3D

# ─── Cấu hình ─────────────────────────────────────────────────
@export var plane_size: Vector2 = Vector2(3.0, 2.0)
@export var grid_color: Color   = Color(0.4, 0.6, 1.0, 0.25)
@export var border_color: Color = Color(0.4, 0.6, 1.0, 0.6)

# ─── Refs ─────────────────────────────────────────────────────
@onready var grid_mesh:        MeshInstance3D = $GridMesh
@onready var collision_shape:  CollisionShape3D = $Body/Shape
@onready var stroke_container: Node3D = $StrokeContainer

# ─── Lưu trữ ─────────────────────────────────────────────────
var strokes: Array = []   # ArrayMesh của từng stroke đã baked

# ─── Khởi tạo từ PlaneGenerator data ─────────────────────────
func initialize(data: Dictionary) -> void:
	plane_size      = data["size"]

	match data["type"]:
		CurveDetector.Type.STRAIGHT:
			global_position = data["center"]
			var right  : Vector3 = data["right"]
			var up     : Vector3 = data["up"]
			var normal : Vector3 = data["normal"]
			global_basis = Basis(right, up, -normal)
			_build_grid()
			_build_collision()

		CurveDetector.Type.CURVED:
			# Node tại origin — points là world coords
			global_position = Vector3.ZERO
			_build_surface_mesh(data["points"], data["up"], data["height"])

		CurveDetector.Type.CLOSED:
			global_position = Vector3.ZERO
			var closed = data["points"].duplicate()
			closed.append(data["points"][0])
			_build_surface_mesh(closed, data["up"], data["height"])

func _build_surface_mesh(points: Array, up: Vector3, height: float) -> void:
	print("_build_surface_mesh: points=", points.size(), " up=", up, " height=", height)
	print("points[0]=", points[0], " points[-1]=", points[-1])
	print("node global_pos=", global_position)
	var hh := height * 0.5

	# Solid mesh
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

	# Border lines
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

	# Collision
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

func _build_grid() -> void:
	var im  := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED

	im.surface_begin(Mesh.PRIMITIVE_LINES)

	var hw        := plane_size.x * 0.5
	var display_h := 25.0
	var hh        := display_h

	im.surface_set_color(border_color)
	im.surface_add_vertex(Vector3(-hw, -hh, 0))
	im.surface_add_vertex(Vector3(-hw,  hh, 0))
	im.surface_add_vertex(Vector3( hw, -hh, 0))
	im.surface_add_vertex(Vector3( hw,  hh, 0))

	im.surface_set_color(border_color * Color(1,1,1,0.25))
	im.surface_add_vertex(Vector3(-hw, -hh, 0))
	im.surface_add_vertex(Vector3( hw, -hh, 0))
	im.surface_add_vertex(Vector3(-hw,  hh, 0))
	im.surface_add_vertex(Vector3( hw,  hh, 0))

	var cols := 5
	for i in range(1, cols):
		var x := -hw + plane_size.x * (float(i) / cols)
		im.surface_set_color(grid_color)
		im.surface_add_vertex(Vector3(x, -hh, 0))
		im.surface_add_vertex(Vector3(x,  hh, 0))

	var spacing   := maxf(plane_size.x / 5.0, 0.3)
	var row_count := int(hh / spacing) + 1
	for i in range(-row_count, row_count + 1):
		var y := float(i) * spacing
		im.surface_set_color(grid_color)
		im.surface_add_vertex(Vector3(-hw, y, 0))
		im.surface_add_vertex(Vector3( hw, y, 0))

	im.surface_end()              # ← thiếu dòng này
	grid_mesh.mesh = im           # ← và 2 dòng này
	grid_mesh.material_override = mat

func _build_collision() -> void:
	var shape  := BoxShape3D.new()
	shape.size  = Vector3(plane_size.x, 50.0, 0.02)
	collision_shape.shape = shape

# ─── Convert world point → tọa độ 2D local trên plane ────────
func world_to_local_2d(world_point: Vector3) -> Vector2:
	var local := to_local(world_point)
	return Vector2(local.x, local.y)

# ─── Thêm stroke đã baked ─────────────────────────────────────
func add_stroke(mesh_inst: MeshInstance3D) -> void:
	stroke_container.add_child(mesh_inst)
	strokes.append(mesh_inst)

func hide_grid() -> void:
	grid_mesh.visible = false

func show_grid() -> void:
	grid_mesh.visible = true
