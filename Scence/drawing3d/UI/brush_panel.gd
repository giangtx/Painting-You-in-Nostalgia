# brush_panel.gd — phiên bản dùng với .tscn
extends Control

signal brush_changed(index: int)
signal brush_size_changed(value: float)
signal color_changed(color: Color)
signal mode_changed(mode: int)

@onready var btn_draw:      Button            = $PanelContainer/ScrollContainer/MainVBox/SectionMode/HBoxContainer/BtnDraw
@onready var btn_erase:     Button            = $PanelContainer/ScrollContainer/MainVBox/SectionMode/HBoxContainer/BtnErase
@onready var brush_list:    VBoxContainer     = $PanelContainer/ScrollContainer/MainVBox/SectionBrush/BrushList
@onready var size_slider:   HSlider           = $PanelContainer/ScrollContainer/MainVBox/SectionSize/HSlider
@onready var size_label:    Label             = $PanelContainer/ScrollContainer/MainVBox/SectionSize/HBoxContainer/SizeLabel
@onready var color_picker:  ColorPickerButton = $PanelContainer/ScrollContainer/MainVBox/SectionColor/ColorPicker
@onready var quick_palette: GridContainer     = $PanelContainer/ScrollContainer/MainVBox/SectionColor/QuickPalette

var _brushes:      Array[BrushPreset] = []
var _active_index: int = 0
var _current_mode: int = 0

const FONT_DEFAULT := Color("#020203ff")
const FONT_ACTIVE  := Color(0.25, 0.52, 1.0)

# ─── Ready ───────────────────────────────────────────────────
func _ready() -> void:
	btn_draw.pressed.connect(func(): _set_mode(0))
	btn_erase.pressed.connect(func(): _set_mode(1))
	size_slider.value_changed.connect(_on_size_changed)
	color_picker.color_changed.connect(func(c): color_changed.emit(c))
	_setup_quick_palette()
	_refresh_mode_buttons()

# ─── Setup từ main.gd ────────────────────────────────────────
func setup(brushes: Array[BrushPreset], init_color: Color, init_size: float) -> void:
	_brushes = brushes
	color_picker.color = init_color
	size_slider.set_block_signals(true)
	size_slider.value = init_size
	size_slider.set_block_signals(false)
	size_label.text = "%.3f" % init_size
	_rebuild_brush_list()

# ─── Mode ────────────────────────────────────────────────────
func _set_mode(mode_val: int) -> void:
	_current_mode = mode_val
	_refresh_mode_buttons()
	mode_changed.emit(mode_val)

func _refresh_mode_buttons() -> void:
	_apply_btn_active(btn_draw,  _current_mode == 0)
	_apply_btn_active(btn_erase, _current_mode == 1)

func _apply_btn_active(btn: Button, active: bool) -> void:
	var c := FONT_ACTIVE if active else FONT_DEFAULT
	btn.add_theme_color_override("font_color",         c)
	btn.add_theme_color_override("font_hover_color",   c)
	btn.add_theme_color_override("font_pressed_color", c)
	btn.add_theme_color_override("font_focus_color",   c)

# ─── Size slider ─────────────────────────────────────────────
func _on_size_changed(value: float) -> void:
	size_label.text = "%.3f" % value
	brush_size_changed.emit(value)

# ─── Brush list ──────────────────────────────────────────────
func _rebuild_brush_list() -> void:
	for c in brush_list.get_children():
		c.queue_free()

	for i in _brushes.size():
		var btn    := Button.new()
		btn.text    = _brushes[i].brush_name
		btn.flat    = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size   = Vector2(0, 32)
		btn.alignment             = HORIZONTAL_ALIGNMENT_LEFT
		# Override tất cả state — chữ không bao giờ thành trắng khi hover/press
		_set_btn_font_color(btn, FONT_DEFAULT)

		var idx := i
		btn.pressed.connect(func(): _on_brush_selected(idx))
		brush_list.add_child(btn)

	_refresh_brush_buttons()

func _on_brush_selected(index: int) -> void:
	_active_index = index
	_refresh_brush_buttons()
	brush_changed.emit(index)

func _refresh_brush_buttons() -> void:
	var children := brush_list.get_children()
	for i in children.size():
		var btn := children[i] as Button
		if btn == null:
			continue
		var c := FONT_ACTIVE if i == _active_index else FONT_DEFAULT
		_set_btn_font_color(btn, c)

func _set_btn_font_color(btn: Button, c: Color) -> void:
	btn.add_theme_color_override("font_color",         c)
	btn.add_theme_color_override("font_hover_color",   c)
	btn.add_theme_color_override("font_pressed_color", c)
	btn.add_theme_color_override("font_focus_color",   c)

# ─── Quick palette ───────────────────────────────────────────
func _setup_quick_palette() -> void:
	for swatch in quick_palette.get_children():
		var btn := swatch as Button
		if btn == null:
			continue
		var sb := btn.get_theme_stylebox("normal") as StyleBoxFlat
		if sb == null:
			continue
		var c := sb.bg_color
		btn.pressed.connect(func():
			color_picker.color = c
			color_changed.emit(c)
		)

# ─── Public ──────────────────────────────────────────────────
func sync_size_to(value: float) -> void:
	size_slider.set_block_signals(true)
	size_slider.value = value
	size_slider.set_block_signals(false)
	size_label.text = "%.3f" % value

func set_mode_external(mode_val: int) -> void:
	_current_mode = mode_val
	_refresh_mode_buttons()
