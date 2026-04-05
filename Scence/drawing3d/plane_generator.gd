# plane_generator.gd
class_name PlaneGenerator

static func compute(points_3d: Array, camera: Camera3D) -> Dictionary:
	if points_3d.size() < 2:
		return {}

	var center    := _compute_center(points_3d)
	var tangent   := _compute_tangent(points_3d)
	var curve_len := _compute_length(points_3d)

	var right   := tangent
	var cam_fwd := -camera.global_basis.z

	# plane_up = vuông góc với tangent, nằm trong mặt phẳng (tangent, cam_fwd)
	# = loại bỏ thành phần tangent ra khỏi cam_fwd, rồi normalize
	# → khi nhìn trên xuống: cam_fwd=(0,-1,0) → up=(0,-1,0) projected → (0,0,±1) → plane đứng
	# → khi nhìn ngang: cam_fwd=(0,0,-1) → up=(0,0,-1) projected → (0,±1,0) → plane nằm ngang
	var cam_fwd_proj := cam_fwd - cam_fwd.dot(right) * right
	var plane_up     := cam_fwd_proj.normalized()

	# Edge case: nét vẽ song song cam_fwd (vẽ thẳng vào màn hình)
	if plane_up.length() < 0.001:
		plane_up = camera.global_basis.y

	# normal = right cross up
	var normal := right.cross(plane_up).normalized()

	# Đảm bảo normal nhìn về phía camera
	var to_cam := camera.global_position - center
	if normal.dot(to_cam) < 0.0:
		normal = -normal

	print("=== Debug ===")
	print("tangent  : ", tangent.snapped(Vector3.ONE * 0.01))
	print("cam_fwd  : ", cam_fwd.snapped(Vector3.ONE * 0.01))
	print("plane_up : ", plane_up.snapped(Vector3.ONE * 0.01))
	print("normal   : ", normal.snapped(Vector3.ONE * 0.01))
	print("center   : ", center.snapped(Vector3.ONE * 0.01))
	print("=============")

	return {
		"center":  center,
		"normal":  normal,
		"tangent": tangent,
		"right":   right,
		"size":    Vector2(curve_len, 9999.0),
		"up":      plane_up,
	}

static func _compute_center(pts: Array) -> Vector3:
	var sum := Vector3.ZERO
	for p in pts:
		sum += p
	return sum / pts.size()

static func _compute_tangent(pts: Array) -> Vector3:
	var t = (pts[-1] - pts[0]).normalized()
	if t.length() < 0.001:
		return Vector3.RIGHT
	return t

static func _compute_length(pts: Array) -> float:
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	return maxf(total, 0.3)
