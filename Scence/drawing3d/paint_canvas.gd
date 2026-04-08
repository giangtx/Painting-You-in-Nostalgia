# paint_canvas.gd
class_name PaintCanvas
extends Node

const PIXELS_PER_UNIT := 128.0
const MAX_SIZE        := 2048

var img:         Image        = null
var img_texture: ImageTexture = null
var img_size:    Vector2i     = Vector2i.ZERO
var has_strokes: bool         = false

var _plane_world_size: Vector2 = Vector2.ZERO

var brush_img:  Image = null
var brush_size: int   = 20
var brush_color: Color = Color.BLACK

func setup(plane_world_size: Vector2) -> void:
	_plane_world_size = plane_world_size
	var w := int(clampf(plane_world_size.x * PIXELS_PER_UNIT, 64, MAX_SIZE))
	var h := int(clampf(plane_world_size.y * PIXELS_PER_UNIT, 64, MAX_SIZE))
	img_size = Vector2i(w, h)
	img = Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img_texture = ImageTexture.create_from_image(img)
	_update_brush()

func set_brush_size(size: int) -> void:
	brush_size = size
	_update_brush()

func set_brush_color(color: Color) -> void:
	brush_color = color
	_update_brush()

func _update_brush() -> void:
	var s      := brush_size
	brush_img   = Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	brush_img.fill(Color(0, 0, 0, 0))
	var center := Vector2(s * 0.5, s * 0.5)
	var radius := s * 0.5
	for x in range(s):
		for y in range(s):
			var dist := Vector2(x, y).distance_to(center)
			if dist <= radius:
				var alpha := 1.0 - smoothstep(radius * 0.5, radius, dist)
				brush_img.set_pixel(x, y, Color(
					brush_color.r, brush_color.g, brush_color.b,
					brush_color.a * alpha
				))

# ─── Paint ────────────────────────────────────────────────────
func paint_at_local(local_pos: Vector2, plane_display_size: Vector2) -> void:
	var uv := _local_to_uv(local_pos, plane_display_size)
	if not _uv_valid(uv):
		return
	_blend_paint(int(uv.x * img_size.x), int(uv.y * img_size.y))
	has_strokes = true
	img_texture.update(img)

func paint_line(from_local: Vector2, to_local: Vector2, plane_display_size: Vector2) -> void:
	var dist  := from_local.distance_to(to_local)
	var steps := maxi(int(dist * PIXELS_PER_UNIT / (brush_size * 0.5)), 1)
	for i in range(steps + 1):
		paint_at_local(from_local.lerp(to_local, float(i) / float(steps)), plane_display_size)

# ─── Erase — set alpha = 0 ────────────────────────────────────
func erase_at_local(local_pos: Vector2, plane_display_size: Vector2) -> void:
	var uv := _local_to_uv(local_pos, plane_display_size)
	if not _uv_valid(uv):
		return
	_erase_pixels(int(uv.x * img_size.x), int(uv.y * img_size.y))
	img_texture.update(img)

func erase_line(from_local: Vector2, to_local: Vector2, plane_display_size: Vector2) -> void:
	var dist  := from_local.distance_to(to_local)
	var steps := maxi(int(dist * PIXELS_PER_UNIT / (brush_size * 0.5)), 1)
	for i in range(steps + 1):
		erase_at_local(from_local.lerp(to_local, float(i) / float(steps)), plane_display_size)

func _erase_pixels(cx: int, cy: int) -> void:
	var half     := brush_size / 2
	var dst_pos  := Vector2i(cx - half, cy - half)
	var img_rect := Rect2i(Vector2i.ZERO, img_size)
	var dst_rect := Rect2i(dst_pos, Vector2i(brush_size, brush_size))
	if not img_rect.intersects(dst_rect):
		return
	var clipped := img_rect.intersection(dst_rect)
	var center  := Vector2(brush_size * 0.5, brush_size * 0.5)
	var radius  := brush_size * 0.5
	for x in range(clipped.size.x):
		for y in range(clipped.size.y):
			var src_x := clipped.position.x - dst_pos.x + x
			var src_y := clipped.position.y - dst_pos.y + y
			var dist  := Vector2(src_x, src_y).distance_to(center)
			if dist > radius:
				continue
			var erase_a := 1.0 - smoothstep(radius * 0.5, radius, dist)
			var dst_x   := clipped.position.x + x
			var dst_y   := clipped.position.y + y
			var cur     := img.get_pixel(dst_x, dst_y)
			var new_a   := clampf(cur.a - erase_a, 0.0, 1.0)
			img.set_pixel(dst_x, dst_y, Color(cur.r, cur.g, cur.b, new_a))

# ─── Helpers ──────────────────────────────────────────────────
func _local_to_uv(local_pos: Vector2, plane_display_size: Vector2) -> Vector2:
	return Vector2(
		(local_pos.x / plane_display_size.x) + 0.5,
		0.5 - (local_pos.y / plane_display_size.y)
	)

func _uv_valid(uv: Vector2) -> bool:
	return uv.x >= 0 and uv.x <= 1 and uv.y >= 0 and uv.y <= 1

func _blend_paint(cx: int, cy: int) -> void:
	var half     := brush_size / 2
	var src_rect := Rect2i(0, 0, brush_size, brush_size)
	var dst_pos  := Vector2i(cx - half, cy - half)
	if not Rect2i(Vector2i.ZERO, img_size).intersects(Rect2i(dst_pos, Vector2i(brush_size, brush_size))):
		return
	img.blend_rect(brush_img, src_rect, dst_pos)

func clear() -> void:
	img.fill(Color(0, 0, 0, 0))
	img_texture.update(img)
	has_strokes = false
