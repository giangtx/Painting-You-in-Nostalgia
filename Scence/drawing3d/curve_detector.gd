# curve_detector.gd
class_name CurveDetector

enum Type { STRAIGHT, CURVED, CLOSED }

static func detect(points_3d: Array) -> Type:
	if points_3d.size() < 2:
		return Type.STRAIGHT

	# Kiểm tra khép kín trước
	var first : Vector3 = points_3d[0]
	var last  : Vector3 = points_3d[-1]
	if first.distance_to(last) < 0.5:
		return Type.CLOSED

	# Kiểm tra độ cong
	if _compute_curvature(points_3d) < 0.15:
		return Type.STRAIGHT

	return Type.CURVED

# Tính độ cong trung bình — so sánh độ dài thực vs khoảng cách thẳng
static func _compute_curvature(pts: Array) -> float:
	var straight_dist = (pts[-1] - pts[0]).length()
	if straight_dist < 0.001:
		return 1.0  # degenerate → coi là cong

	var curve_len := 0.0
	for i in range(pts.size() - 1):
		curve_len += pts[i].distance_to(pts[i + 1])

	# ratio = 1.0 → thẳng hoàn toàn
	# ratio > 1.0 → càng cong càng lớn
	var ratio = curve_len / straight_dist
	return ratio - 1.0
