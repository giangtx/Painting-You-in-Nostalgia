# brush_preset.gd
class_name BrushPreset
extends Resource

@export var brush_name: String    = "New Brush"

# PNG: nền transparent, brush shape dùng alpha channel
@export var brush_texture: Texture2D = null

@export_group("Stroke")
@export var brush_size:      float = 0.08  # width/height của stamp (world units)
@export var thickness:       float = 0.5   # độ dày theo chiều sâu (0=flat, 1=cube)
@export var spacing_percent: float = 0.2   # khoảng cách stamp = brush_size × spacing_percent
@export var opacity:         float = 1.0

@export_group("Jitter")
@export var angle_jitter:   float = 0.0   # random xoay (radians)
@export var size_jitter:    float = 0.1   # random scale ±size_jitter
@export var opacity_jitter: float = 0.1   # random opacity ±opacity_jitter
@export var scatter:        float = 0.0   # random offset ±scatter × brush_size
