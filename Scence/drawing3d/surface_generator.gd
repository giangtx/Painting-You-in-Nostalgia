# surface_generator.gd
class_name SurfaceGenerator

const EXTRUDE_HEIGHT := 25.0  # chiều cao dựng theo UP

static func compute(points_3d: Array, camera: Camera3D) -> Dictionary:
	if points_3d.size() < 2:
		return {}

	var type := CurveDetector.detect(points_3d)

	match type:
		CurveDetector.Type.STRAIGHT:
			return _compute_flat(points_3d, camera)
		CurveDetector.Type.CURVED:
			return _compute_curved(points_3d, camera)
		CurveDetector.Type.CLOSED:
			return _compute_cylinder(points_3d, camera)
		_:
			return _compute_flat(points_3d, camera)

# ── Flat plane (code cũ giữ nguyên) ─────────────────────────
static func _compute_flat(points_3d: Array, camera: Camera3D) -> Dictionary:
	var center    := _center(points_3d)
	var tangent   := _tangent(points_3d)
	var curve_len := _length(points_3d)
	var cam_fwd   := -camera.global_basis.z
	var right     := tangent
	var cam_fwd_proj := cam_fwd - cam_fwd.dot(right) * right
	var plane_up     := cam_fwd_proj.normalized()
	if plane_up.length() < 0.001:
		plane_up = camera.global_basis.y
	var normal := right.cross(plane_up).normalized()
	var to_cam := camera.global_position - center
	if normal.dot(to_cam) < 0.0:
		normal = -normal
	return {
		"type":    CurveDetector.Type.STRAIGHT,
		"center":  center,
		"normal":  normal,
		"right":   right,
		"up":      plane_up,
		"size":    Vector2(curve_len, 9999.0),
		"points":  points_3d,
	}

# ── Curved surface ────────────────────────────────────────────
# surface_generator.gd — _compute_curved()
# surface_generator.gd — sửa _compute_curved
static func _compute_curved(points_3d: Array, camera: Camera3D) -> Dictionary:
	var center  := _center(points_3d)
	var tangent := _tangent(points_3d)
	var cam_fwd := -camera.global_basis.z

	# up = vuông góc với tangent nét vẽ, nằm trong mặt phẳng camera
	# loại bỏ thành phần song song với tangent ra khỏi cam_fwd
	var cam_fwd_proj := cam_fwd - cam_fwd.dot(tangent) * tangent
	var extrude_dir  := cam_fwd_proj.normalized()

	# Edge case: nét vẽ song song với cam_fwd
	if extrude_dir.length() < 0.001:
		extrude_dir = camera.global_basis.y

	return {
		"type":    CurveDetector.Type.CURVED,
		"center":  center,
		"points":  points_3d,
		"up":      extrude_dir,
		"height":  25.0,
		"normal":  Vector3.ZERO,
		"right":   Vector3.ZERO,
		"size":    Vector2.ZERO,
	}

# ── Cylinder surface ──────────────────────────────────────────
static func _compute_cylinder(points_3d: Array, camera: Camera3D) -> Dictionary:
	var center  := _center(points_3d)
	var tangent := _tangent(points_3d)
	var cam_fwd := -camera.global_basis.z

	# Dùng cùng logic với CURVED
	var cam_fwd_proj := cam_fwd - cam_fwd.dot(tangent) * tangent
	var extrude_dir  := cam_fwd_proj.normalized()

	if extrude_dir.length() < 0.001:
		extrude_dir = camera.global_basis.y

	return {
		"type":    CurveDetector.Type.CLOSED,
		"center":  center,
		"points":  points_3d,
		"up":      extrude_dir,
		"height":  EXTRUDE_HEIGHT,
		"normal":  Vector3.ZERO,
		"right":   Vector3.ZERO,
		"size":    Vector2.ZERO,
	}

# ── Helpers ───────────────────────────────────────────────────
static func _center(pts: Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts: s += p
	return s / pts.size()

static func _tangent(pts: Array) -> Vector3:
	var t = (pts[-1] - pts[0]).normalized()
	return t if t.length() > 0.001 else Vector3.RIGHT

static func _length(pts: Array) -> float:
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	return maxf(total, 0.3)
