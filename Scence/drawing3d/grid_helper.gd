# grid_helper.gd
extends MeshInstance3D

@export var axis_length: float = 9999.0
@export var color_x: Color = Color(0.92, 0.22, 0.22, 0.6)  # đỏ
@export var color_y: Color = Color(0.25, 0.78, 0.25, 0.6)  # xanh lá
@export var color_z: Color = Color(0.22, 0.45, 0.92, 0.6)  # xanh dương

func _ready() -> void:
	_build()

func _build() -> void:
	var im  := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA

	im.surface_begin(Mesh.PRIMITIVE_LINES)

	# Trục X
	im.surface_set_color(color_x)
	im.surface_add_vertex(Vector3(-axis_length, 0, 0))
	im.surface_set_color(color_x)
	im.surface_add_vertex(Vector3( axis_length, 0, 0))

	# Trục Y
	im.surface_set_color(color_y)
	im.surface_add_vertex(Vector3(0, -axis_length, 0))
	im.surface_set_color(color_y)
	im.surface_add_vertex(Vector3(0,  axis_length, 0))

	# Trục Z
	im.surface_set_color(color_z)
	im.surface_add_vertex(Vector3(0, 0, -axis_length))
	im.surface_set_color(color_z)
	im.surface_add_vertex(Vector3(0, 0,  axis_length))

	im.surface_end()
	mesh              = im
	material_override = mat

func toggle() -> void:
	visible = !visible
