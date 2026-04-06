# stroke_builder.gd
class_name StrokeBuilder
extends Node

@export var stroke_width: float = 0.05
@export var stroke_color: Color = Color.BLACK

const SIDES    := 6       # số cạnh của cross-section
const MIN_DIST := 0.005

var _points:       Array[Vector3] = []
var _camera:       Camera3D       = null
var _cam_forward:  Vector3        = Vector3.ZERO
var _preview_inst: MeshInstance3D = null
var _parent:       Node3D         = null

func setup(camera: Camera3D, parent: Node3D) -> void:
	_camera = camera
	_parent = parent

func start_stroke(world_point: Vector3) -> void:
	_points.clear()
	_points.append(world_point)
	_cam_forward = -_camera.global_basis.z

	if _preview_inst != null:
		_preview_inst.queue_free()
	_preview_inst        = MeshInstance3D.new()
	_preview_inst.top_level = true
	_parent.add_child(_preview_inst)

func add_point(world_point: Vector3) -> void:
	if _points.is_empty():
		return
	if world_point.distance_to(_points.back()) < MIN_DIST:
		return
	_points.append(world_point)
	_update_preview()

func finish_stroke() -> MeshInstance3D:
	if _points.size() < 2:
		if _preview_inst:
			_preview_inst.queue_free()
			_preview_inst = null
		_points.clear()
		return null

	var baked := _build_cylinder(_points)
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null
	_points.clear()
	return baked

func cancel_stroke() -> void:
	if _preview_inst:
		_preview_inst.queue_free()
		_preview_inst = null
	_points.clear()

func is_drawing() -> bool:
	return not _points.is_empty()

func _update_preview() -> void:
	if _preview_inst == null or _points.size() < 2:
		return
	var built := _build_cylinder(_points)
	if built:
		_preview_inst.mesh              = built.mesh
		_preview_inst.material_override = built.material_override
		built.queue_free()

# ─── Build cylindrical stroke ─────────────────────────────────
func _build_cylinder(points: Array) -> MeshInstance3D:
	if points.size() < 2:
		return null

	var radius := stroke_width * 0.5

	# ── Bước 1: tính frame (tangent, normal, binormal) tại mỗi điểm
	# Dùng Parallel Transport để tránh twisting
	var tangents  : Array[Vector3] = []
	var normals   : Array[Vector3] = []
	var binormals : Array[Vector3] = []

	# Tangent tại mỗi điểm
	for i in range(points.size()):
		var t : Vector3
		if i == 0:
			t = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			t = (points[i] - points[i-1]).normalized()
		else:
			var a = (points[i]   - points[i-1]).normalized()
			var b = (points[i+1] - points[i]).normalized()
			t      = (a + b).normalized()
			if t.length() < 0.001:
				t = a
		tangents.append(t)

	# Normal đầu tiên = từ cam_forward
	var n0 := _cam_forward.cross(tangents[0]).normalized()
	if n0.length() < 0.001:
		n0 = Vector3.UP.cross(tangents[0]).normalized()
	if n0.length() < 0.001:
		n0 = Vector3.RIGHT
	normals.append(n0)
	binormals.append(tangents[0].cross(n0).normalized())

	# Parallel transport: propagate frame dọc theo curve
	for i in range(1, points.size()):
		var t_prev := tangents[i - 1]
		var t_curr := tangents[i]
		var n_prev := normals[i - 1]

		# Rotate normal theo sự thay đổi tangent
		var axis  := t_prev.cross(t_curr)
		var angle := t_prev.angle_to(t_curr)

		var n_curr : Vector3
		if axis.length() < 0.0001 or absf(angle) < 0.0001:
			n_curr = n_prev
		else:
			n_curr = n_prev.rotated(axis.normalized(), angle)

		# Re-orthogonalize để tránh drift
		n_curr = (n_curr - t_curr * t_curr.dot(n_curr)).normalized()
		if n_curr.length() < 0.001:
			n_curr = normals[i - 1]

		normals.append(n_curr)
		binormals.append(t_curr.cross(n_curr).normalized())

	# ── Bước 2: tạo ring vertices tại mỗi điểm ───────────────
	# ring[i][j] = vị trí vertex j trên ring i
	var rings : Array = []
	for i in range(points.size()):
		var ring : Array[Vector3] = []
		for j in range(SIDES):
			var angle := TAU * float(j) / float(SIDES)
			var offset := normals[i] * cos(angle) * radius \
						+ binormals[i] * sin(angle) * radius
			ring.append(points[i] + offset)
		rings.append(ring)

	# ── Bước 3: build mesh từ rings ───────────────────────────
	var verts  := PackedVector3Array()
	var uvs    := PackedVector2Array()
	var colors := PackedColorArray()

	var total_len := 0.0
	var lens      : Array[float] = [0.0]
	for i in range(1, points.size()):
		total_len += (points[i] - points[i-1]).length()
		lens.append(total_len)

	# Nối các ring liền kề thành quad strip
	for i in range(points.size() - 1):
		var u0 := lens[i]   / maxf(total_len, 0.001)
		var u1 := lens[i+1] / maxf(total_len, 0.001)

		for j in range(SIDES):
			var j_next := (j + 1) % SIDES

			var v0 := float(j)      / float(SIDES)
			var v1 := float(j_next) / float(SIDES)

			var a : Vector3 = rings[i][j]
			var b : Vector3 = rings[i][j_next]
			var c : Vector3 = rings[i+1][j]
			var d : Vector3 = rings[i+1][j_next]

			# Triangle 1
			verts.append(a); uvs.append(Vector2(u0, v0)); colors.append(stroke_color)
			verts.append(b); uvs.append(Vector2(u0, v1)); colors.append(stroke_color)
			verts.append(d); uvs.append(Vector2(u1, v1)); colors.append(stroke_color)
			# Triangle 2
			verts.append(a); uvs.append(Vector2(u0, v0)); colors.append(stroke_color)
			verts.append(d); uvs.append(Vector2(u1, v1)); colors.append(stroke_color)
			verts.append(c); uvs.append(Vector2(u1, v0)); colors.append(stroke_color)

	if verts.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR]  = colors

	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.render_priority            = 1

	var mi              := MeshInstance3D.new()
	mi.mesh              = amesh
	mi.material_override = mat
	mi.top_level         = true
	return mi
