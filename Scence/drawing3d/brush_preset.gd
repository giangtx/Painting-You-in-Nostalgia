# brush_preset.gd
class_name BrushPreset
extends Resource

enum StrokeType { LINE, SHAPE }
enum ShapeType  { SQUARE, RECTANGLE, CIRCLE }

const PX_TO_UNIT := 0.01  # 1 pixel = 0.01 world unit

@export var brush_name:   String     = "New Brush"
@export var stroke_type:  StrokeType = StrokeType.LINE
@export var shape_type:   ShapeType  = ShapeType.SQUARE  # chỉ dùng khi stroke_type == SHAPE

@export_group("Size")
# Tất cả đơn vị: pixel (1px = PX_TO_UNIT world unit)
@export var size:      float = 10.0  # width của LINE / SHAPE; diameter của CIRCLE
@export var height:    float = 10.0  # chỉ cho RECTANGLE (chiều cao trong plane)
@export var thickness: float = 5.0   # chiều nổi khỏi plane
@export var opacity:   float = 1.0

# ── Helpers ──────────────────────────────────────────────────────
func size_u()      -> float: return size      * PX_TO_UNIT
func height_u()    -> float: return height    * PX_TO_UNIT
func thickness_u() -> float: return thickness * PX_TO_UNIT
