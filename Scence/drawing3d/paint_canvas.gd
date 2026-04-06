# paint_canvas.gd
class_name PaintCanvas
extends Node

# ─── Config ───────────────────────────────────────────────────
const PIXELS_PER_UNIT := 128.0   # độ phân giải: 128px mỗi world unit
const MAX_SIZE        := 2048    # giới hạn tối đa

# ─── State ────────────────────────────────────────────────────
var img:         Image        = null
var img_texture: ImageTexture = null
var img_size:    Vector2i     = Vector2i.ZERO
var has_strokes: bool         = false   # lazy creation flag

# Kích thước plane trong world (để tính UV)
var _plane_world_size: Vector2 = Vector2.ZERO

# ─── Brush ────────────────────────────────────────────────────
var brush_img:  Image = null
var brush_size: int   = 5
var brush_color: Color = Color.BLACK

# ─── Setup ────────────────────────────────────────────────────
func setup(plane_world_size: Vector2) -> void:
	_plane_world_size = plane_world_size

	# Tính resolution theo kích thước thực của plane
	var w := int(clampf(plane_world_size.x * PIXELS_PER_UNIT, 64, MAX_SIZE))
	var h := int(clampf(plane_world_size.y * PIXELS_PER_UNIT, 64, MAX_SIZE))
	img_size = Vector2i(w, h)

	# Tạo image trong suốt
	img = Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	img_texture = ImageTexture.create_from_image(img)

	_update_brush()

# ─── Brush ────────────────────────────────────────────────────
func set_brush_size(size: int) -> void:
	brush_size = size
	_update_brush()

func set_brush_color(color: Color) -> void:
	brush_color = color
	_update_brush()

func _update_brush() -> void:
	# Tạo brush hình tròn mềm (soft circle)
	var s    := brush_size
	brush_img = Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	brush_img.fill(Color(0, 0, 0, 0))

	var center := Vector2(s * 0.5, s * 0.5)
	var radius := s * 0.5

	for x in range(s):
		for y in range(s):
			var dist := Vector2(x, y).distance_to(center)
			if dist <= radius:
				# Soft edge: alpha giảm dần ở rìa
				var alpha := 1.0 - smoothstep(radius * 0.5, radius, dist)
				brush_img.set_pixel(x, y, Color(brush_color.r, brush_color.g, brush_color.b, brush_color.a * alpha))

# ─── Paint ────────────────────────────────────────────────────
# local_pos: tọa độ local của plane (-hw..hw, -hh..hh)
# plane_display_size: kích thước hiển thị thực của plane
func paint_at_local(local_pos: Vector2, plane_display_size: Vector2) -> void:
	var uv := Vector2(
		(local_pos.x / plane_display_size.x) + 0.5,
		# Flip Y: local Y dương = lên trên, UV Y dương = xuống dưới
		0.5 - (local_pos.y / plane_display_size.y)
	)

	if uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1:
		return

	var px := int(uv.x * img_size.x)
	var py := int(uv.y * img_size.y)

	_blend_brush(px, py)
	has_strokes = true
	img_texture.update(img)

func _blend_brush(cx: int, cy: int) -> void:
	var half := brush_size / 2
	var src_rect := Rect2i(0, 0, brush_size, brush_size)
	var dst_pos  := Vector2i(cx - half, cy - half)

	# Clamp dst để không vẽ ngoài bounds
	var dst_rect := Rect2i(dst_pos, Vector2i(brush_size, brush_size))
	var img_rect := Rect2i(Vector2i.ZERO, img_size)
	if not img_rect.intersects(dst_rect):
		return

	img.blend_rect(brush_img, src_rect, dst_pos)

# ─── Interpolate giữa 2 điểm (vẽ mượt khi drag nhanh) ────────
func paint_line(from_local: Vector2, to_local: Vector2, plane_display_size: Vector2) -> void:
	var dist    := from_local.distance_to(to_local)
	var steps   := maxi(int(dist * PIXELS_PER_UNIT / (brush_size * 0.5)), 1)

	for i in range(steps + 1):
		var t   := float(i) / float(steps)
		var pos := from_local.lerp(to_local, t)
		paint_at_local(pos, plane_display_size)

# ─── Clear ────────────────────────────────────────────────────
func clear() -> void:
	img.fill(Color(0, 0, 0, 0))
	img_texture.update(img)
	has_strokes = false
