# brush_panel.gd — phiên bản dùng với .tscn
extends Control

signal brush_changed(index: int)
signal brush_size_changed(value: float)
signal brush_opacity_changed(value: float)
signal brush_thickness_changed(value: float)
signal color_changed(color: Color)
signal mode_changed(mode: int)

@onready var btn_draw:         Button            = $PanelContainer/ScrollContainer/MainVBox/SectionMode/HBoxContainer/BtnDraw
@onready var btn_erase:        Button            = $PanelContainer/ScrollContainer/MainVBox/SectionMode/HBoxContainer/BtnErase
@onready var brush_list:       VBoxContainer     = $PanelContainer/ScrollContainer/MainVBox/SectionBrush/BrushList
@onready var size_slider:      HSlider           = $PanelContainer/ScrollContainer/MainVBox/SectionSize/HBoxContainer/SizeSlider
@onready var size_label:       Label             = $PanelContainer/ScrollContainer/MainVBox/SectionSize/HBoxContainer/SizeLabel
@onready var opacity_slider:   HSlider           = $PanelContainer/ScrollContainer/MainVBox/SectionOpacity/HBoxContainer/OpacitySlider
@onready var opacity_label:    Label             = $PanelContainer/ScrollContainer/MainVBox/SectionOpacity/HBoxContainer/OpacityLabel
@onready var thickness_slider: HSlider           = $PanelContainer/ScrollContainer/MainVBox/SectionThickness/HBoxContainer/ThicknessSlider
@onready var thickness_label:  Label             = $PanelContainer/ScrollContainer/MainVBox/SectionThickness/HBoxContainer/ThicknessLabel
@onready var color_picker:     ColorPickerButton = $PanelContainer/ScrollContainer/MainVBox/SectionColor/ColorPicker
@onready var quick_palette:    GridContainer     = $PanelContainer/ScrollContainer/MainVBox/SectionColor/QuickPalette

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
	opacity_slider.value_changed.connect(_on_opacity_changed)
	thickness_slider.value_changed.connect(_on_thickness_changed)
	color_picker.color_changed.connect(func(c): color_changed.emit(c))
	_setup_quick_palette()
	_refresh_mode_buttons()

# ─── Setup từ main.gd ────────────────────────────────────────
func setup(brushes: Array[BrushPreset], init_color: Color, init_size: float) -> void:
	_brushes = brushes
	color_picker.color = init_color

	_set_slider(size_slider,      size_label,      init_size, "%.3f")

	var preset := brushes[0] if not brushes.is_empty() else null
	_set_slider(opacity_slider,   opacity_label,   preset.opacity   if preset else 1.0,  "%.2f")
	_set_slider(thickness_slider, thickness_label, preset.thickness if preset else 0.5,  "%.2f")

	_rebuild_brush_list()

# ─── Slider helper — block signal khi set programmatic ───────
func _set_slider(slider: HSlider, label: Label, value: float, fmt: String) -> void:
	slider.set_block_signals(true)
	slider.value = value
	slider.set_block_signals(false)
	label.text = fmt % value

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

# ─── Slider handlers ─────────────────────────────────────────
func _on_size_changed(value: float) -> void:
	size_label.text = "%.3f" % value
	brush_size_changed.emit(value)

func _on_opacity_changed(value: float) -> void:
	opacity_label.text = "%.2f" % value
	brush_opacity_changed.emit(value)

func _on_thickness_changed(value: float) -> void:
	thickness_label.text = "%.2f" % value
	brush_thickness_changed.emit(value)

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
		_set_btn_font_color(btn, FONT_ACTIVE if i == _active_index else FONT_DEFAULT)

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
	_set_slider(size_slider, size_label, value, "%.3f")

func sync_opacity_to(value: float) -> void:
	_set_slider(opacity_slider, opacity_label, value, "%.2f")

func sync_thickness_to(value: float) -> void:
	_set_slider(thickness_slider, thickness_label, value, "%.2f")

func set_mode_external(mode_val: int) -> void:
	_current_mode = mode_val
	_refresh_mode_buttons()
