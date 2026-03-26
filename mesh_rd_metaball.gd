extends Node3D

const SURFACE_SHADER: Shader = preload("res://shaders/mesh_surface.gdshader")
const RIBBON_SHADER: Shader = preload("res://shaders/ribbon_surface.gdshader")

const MC_CELLS := 64
const MC_LOCAL := 4
const MC_MAX_VERTS_PER_CELL := 4
const MC_MAX_IDXS_PER_CELL := 4

const TERRAIN_RES := 129
const TERRAIN_LOCAL := 8

const RIBBON_COUNT := 1024
const RIBBON_SEGMENTS := 48
const RIBBON_LOCAL := 64

const INDIRECT_CMD_SIZE := 24

@onready var camera: Camera3D = $Camera3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var ground_plane: MeshInstance3D = $GroundPlane
@onready var case_selector: OptionButton = $CanvasLayer/PanelContainer/MarginContainer/VBoxContainer/CaseSelector
@onready var case_description: Label = $CanvasLayer/PanelContainer/MarginContainer/VBoxContainer/CaseDescription

var rd: RenderingDevice
var mesh_rd: MeshRD
var shader_rids: Array[RID] = []
var pipelines: Array[RID] = []
var vertex_buffers: Array[RID] = []
var attribute_buffers: Array[RID] = []
var index_buffers: Array[RID] = []
var indirect_buffers: Array[RID] = []
var uniform_sets: Array[RID] = []
var max_vertex_counts: PackedInt32Array = []
var max_index_counts: PackedInt32Array = []
var elapsed_time := 0.0
var current_case := 0
var cases: Array[Dictionary] = []
var terrain_params := {
	"frequency": 0.035,
	"amplitude": 18.0,
	"ridge_strength": 10.0,
	"warp_strength": 0.5,
	"detail_strength": 3.0,
	"base_offset": -6.0,
}
var terrain_panel: PanelContainer

func _ready() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("Failed to get rendering device.")
		return
	_init_cases()
	if not _compile_all_shaders():
		_cleanup()
		return
	_setup_ui()
	if not _switch_case(0):
		_cleanup()
		return
	print("MeshRD demo ready. Right-click + WASD to fly camera.")


func _exit_tree() -> void:
	_cleanup()


func _init_cases() -> void:
	var mc_v := MC_CELLS * MC_CELLS * MC_CELLS * MC_MAX_VERTS_PER_CELL
	var mc_i := MC_CELLS * MC_CELLS * MC_CELLS * MC_MAX_IDXS_PER_CELL
	var ter_v := TERRAIN_RES * TERRAIN_RES
	var ter_i := (TERRAIN_RES - 1) * (TERRAIN_RES - 1) * 6
	var rib_v := RIBBON_COUNT * (RIBBON_SEGMENTS + 1) * 2
	var rib_i := RIBBON_COUNT * RIBBON_SEGMENTS * 6

	var ter_mat := {
		"visualization_mode": 1.0,
		"roughness_value": 0.85,
		"metallic_value": 0.05,
		"height_min": -5.0,
		"height_max": 12.0,
		"low_color": Color(0.05, 0.12, 0.18),
		"mid_color": Color(0.17, 0.49, 0.23),
		"high_color": Color(0.83, 0.78, 0.56),
		"rock_color": Color(0.44, 0.39, 0.34),
	}

	cases = [
		{
			"name": "Dual Metaballs",
			"desc": "Two animated metaball iso-surfaces (marching tetrahedra).",
			"type": "mc",
			"shader_parts": [
				"res://shaders/include/buffers.txt",
				"res://shaders/include/noise.txt",
				"res://shaders/fields/metaball.txt",
				"res://shaders/include/marching_cube.txt",
			],
			"vert_count": mc_v,
			"idx_count": mc_i,
			"extent": 1.35,
			"iso": 1.0,
			"grad_step": 0.035,
			"cam_pos": Vector3(2.8, 2.1, 3.4),
			"cam_target": Vector3.ZERO,
			"surfaces": [
				{
					"offset": Vector3(-1.15, 0.0, 0.0),
					"phase": 0.0,
					"mat": {
						"albedo_tint": Color(1.0, 0.52, 0.30),
						"roughness_value": 0.08,
						"metallic_value": 1.0,
					},
				},
				{
					"offset": Vector3(1.15, 0.0, 0.0),
					"phase": 1.7,
					"mat": {
						"albedo_tint": Color(0.24, 0.78, 1.0),
						"roughness_value": 0.2,
						"metallic_value": 0.55,
					},
				},
			],
		},
		{
			"name": "Terrain Clipmap",
			"desc": "GPU-driven clipmap terrain. Grid follows camera with 2 LOD rings and FBM heightmap.",
			"type": "terrain",
			"shader_parts": [
				"res://shaders/terrain/buffers.txt",
				"res://shaders/include/noise.txt",
				"res://shaders/terrain/main.txt",
			],
			"vert_count": ter_v,
			"idx_count": ter_i,
			"cam_pos": Vector3(0.0, 15.0, 20.0),
			"cam_target": Vector3(0.0, 0.0, 0.0),
			"surfaces": [
				{
					"spacing": 0.5,
					"mat": ter_mat,
				},
				{
					"spacing": 2.0,
					"mat": ter_mat,
				},
			],
		},
		{
			"name": "Ribbon Swarm",
			"desc": "1024 GPU-driven ribbons (%d verts, %d tris)." % [rib_v, rib_i / 3.0],
			"type": "ribbon",
			"shader_parts": [
				"res://shaders/ribbon/buffers.txt",
				"res://shaders/ribbon/main.txt",
			],
			"vert_count": rib_v,
			"idx_count": rib_i,
			"cam_pos": Vector3(4.0, 3.0, 6.0),
			"cam_target": Vector3(0.0, 0.5, 0.0),
			"surfaces": [
				{
					"width": 0.025,
					"trail_length": 4.0,
					"mat": {
						"roughness_value": 0.1,
						"metallic_value": 0.9,
						"emission_strength": 2.5,
					},
				},
			],
		},
	]

func _compile_all_shaders() -> bool:
	for c in cases:
		var source := _assemble_shader(c["shader_parts"])
		if source.is_empty():
			return false
		var shader_src := RDShaderSource.new()
		shader_src.source_compute = source
		var spirv := rd.shader_compile_spirv_from_source(shader_src)
		var err := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not err.is_empty():
			push_error("Shader compile error (%s): %s" % [c["name"], err])
			return false
		var sid := rd.shader_create_from_spirv(spirv)
		if not sid.is_valid():
			push_error("shader_create_from_spirv failed: %s" % c["name"])
			return false
		var pid := rd.compute_pipeline_create(sid)
		if not pid.is_valid():
			rd.free_rid(sid)
			push_error("compute_pipeline_create failed: %s" % c["name"])
			return false
		shader_rids.append(sid)
		pipelines.append(pid)
	return true


func _assemble_shader(parts: Array) -> String:
	var result := PackedStringArray()
	for path in parts:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			push_error("Failed to read: %s" % path)
			return ""
		result.append(text)
	return "\n".join(result)

func _setup_ui() -> void:
	case_selector.clear()
	for c in cases:
		case_selector.add_item(c["name"])
	case_selector.select(current_case)
	if not case_selector.item_selected.is_connected(_on_case_selected):
		case_selector.item_selected.connect(_on_case_selected)
	case_description.text = cases[current_case]["desc"]
	var wireframe_btn := CheckButton.new()
	wireframe_btn.text = "Wireframe"
	wireframe_btn.toggled.connect(func(on: bool) -> void:
		RenderingServer.set_debug_generate_wireframes(true)
		var vp := get_viewport()
		vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if on else Viewport.DEBUG_DRAW_DISABLED
	)
	$CanvasLayer/PanelContainer/MarginContainer/VBoxContainer.add_child(wireframe_btn)
	_build_terrain_panel()


func _build_terrain_panel() -> void:
	terrain_panel = PanelContainer.new()
	terrain_panel.anchor_left = 1.0
	terrain_panel.anchor_right = 1.0
	terrain_panel.anchor_top = 0.0
	terrain_panel.anchor_bottom = 0.0
	terrain_panel.offset_left = -320.0
	terrain_panel.offset_top = 16.0
	terrain_panel.offset_right = -16.0
	terrain_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	terrain_panel.visible = false
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	terrain_panel.add_child(margin)
	var vbox := VBoxContainer.new()
	margin.add_child(vbox)
	var title := Label.new()
	title.text = "Noise Parameters"
	vbox.add_child(title)
	var sliders := [
		["frequency", 0.005, 0.15, 0.035],
		["amplitude", 0.0, 40.0, 18.0],
		["ridge_strength", 0.0, 25.0, 10.0],
		["warp_strength", 0.0, 2.0, 0.5],
		["detail_strength", 0.0, 10.0, 3.0],
		["base_offset", -20.0, 10.0, -6.0],
	]
	for s in sliders:
		var key: String = s[0]
		var hbox := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = key
		lbl.custom_minimum_size.x = 110
		hbox.add_child(lbl)
		var slider := HSlider.new()
		slider.min_value = s[1]
		slider.max_value = s[2]
		slider.value = s[3]
		slider.step = (s[2] - s[1]) / 200.0
		slider.custom_minimum_size.x = 130
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(slider)
		var val_lbl := Label.new()
		val_lbl.text = "%.3f" % s[3]
		val_lbl.custom_minimum_size.x = 50
		hbox.add_child(val_lbl)
		vbox.add_child(hbox)
		slider.value_changed.connect(func(v: float) -> void:
			terrain_params[key] = v
			val_lbl.text = "%.3f" % v
		)
	$CanvasLayer.add_child(terrain_panel)

func _on_case_selected(index: int) -> void:
	if index == current_case:
		return
	if not _switch_case(index):
		_cleanup()
		push_error("Failed to switch to: %s" % cases[index]["name"])


func _switch_case(index: int) -> bool:
	if index < 0 or index >= cases.size():
		return false
	_release_surface_resources()
	current_case = index
	elapsed_time = 0.0
	var c := cases[index]
	case_selector.select(index)
	case_description.text = c["desc"]
	camera.reset_to(c["cam_pos"], c.get("cam_target", Vector3.ZERO))
	ground_plane.visible = c["type"] != "terrain"
	if terrain_panel:
		terrain_panel.visible = c["type"] == "terrain"

	mesh_rd = _create_mesh(c)
	if mesh_rd == null:
		return false
	mesh_instance.mesh = mesh_rd
	if not _bind_buffers():
		return false
	if not _create_uniforms():
		return false
	return true


func _create_mesh(c: Dictionary) -> MeshRD:
	var m := MeshRD.new()
	var vert_count: int = c["vert_count"]
	var idx_count: int = c["idx_count"]
	var fmt: int = (
		Mesh.ARRAY_FORMAT_VERTEX
		| Mesh.ARRAY_FORMAT_INDEX
		| Mesh.ARRAY_FORMAT_CUSTOM0
	)
	fmt |= int(Mesh.ARRAY_CUSTOM_RGB_FLOAT) << int(Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	for surf in c["surfaces"]:
		var aabb := _surface_aabb(c, surf)
		var shader := RIBBON_SHADER if c["type"] == "ribbon" else SURFACE_SHADER
		m.add_surface_storage(
			fmt, Mesh.PRIMITIVE_TRIANGLES, vert_count, idx_count,
			aabb, _create_material(surf["mat"], shader), Vector4(),
			RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT,
			RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT,
			RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT,
		)
	m.set_custom_aabb(_mesh_aabb(c))
	return m


func _surface_aabb(c: Dictionary, surf: Dictionary) -> AABB:
	match c["type"]:
		"terrain":
			var half = float(TERRAIN_RES) * surf.get("spacing", 0.5) * 0.5
			return AABB(Vector3(-half, -50.0, -half), Vector3(half * 2.0, 100.0, half * 2.0))
		"ribbon":
			return AABB(Vector3(-5, -5, -5), Vector3(10, 10, 10))
		_:
			var ext: float = c.get("extent", 2.0)
			var off: Vector3 = surf.get("offset", Vector3.ZERO)
			return AABB(off - Vector3(ext, ext, ext), Vector3(ext, ext, ext) * 2.0)


func _mesh_aabb(c: Dictionary) -> AABB:
	var surfaces: Array = c["surfaces"]
	var aabb := _surface_aabb(c, surfaces[0])
	for i in range(1, surfaces.size()):
		aabb = aabb.merge(_surface_aabb(c, surfaces[i]))
	return aabb


func _create_material(mat_params: Dictionary, shader: Shader = SURFACE_SHADER) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	for key in mat_params:
		mat.set_shader_parameter(key, mat_params[key])
	return mat


func _process(delta: float) -> void:
	if rd == null or uniform_sets.is_empty():
		return
	elapsed_time += delta
	var c := cases[current_case]

	for buf in indirect_buffers:
		_reset_indirect(buf)

	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipelines[current_case])
	for si in range(uniform_sets.size()):
		rd.compute_list_bind_uniform_set(cl, uniform_sets[si], 0)
		var pc := _build_push_constants(c, si)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		var d := _dispatch_size(c)
		rd.compute_list_dispatch(cl, d.x, d.y, d.z)
		rd.compute_list_add_barrier(cl)
	rd.compute_list_end()


func _dispatch_size(c: Dictionary) -> Vector3i:
	match c["type"]:
		"terrain":
			var g := TERRAIN_LOCAL
			return Vector3i(ceili(float(TERRAIN_RES) / g), ceili(float(TERRAIN_RES) / g), 1)
		"ribbon":
			return Vector3i(ceili(float(RIBBON_SEGMENTS + 1) / RIBBON_LOCAL), RIBBON_COUNT, 1)
		_:
			var g := MC_LOCAL
			return Vector3i(ceili(float(MC_CELLS) / g), ceili(float(MC_CELLS) / g), ceili(float(MC_CELLS) / g))


func _build_push_constants(c: Dictionary, si: int) -> PackedByteArray:
	var pc := PackedByteArray()
	var is_terrain : bool = c["type"] == "terrain"
	pc.resize(96 if is_terrain else 64)
	var surf: Dictionary = c["surfaces"][si]
	match c["type"]:
		"terrain":
			var spacing: float = surf.get("spacing", 0.5)
			# All LOD rings snap to the coarsest grid to keep centers aligned
			var max_spacing := 0.0
			for s in c["surfaces"]:
				max_spacing = maxf(max_spacing, s.get("spacing", 0.5))
			var snap_x := snappedf(camera.global_position.x, max_spacing)
			var snap_z := snappedf(camera.global_position.z, max_spacing)
			var inner_clip_half := 0.0
			if si > 0:
				var finer_spacing: float = c["surfaces"][si - 1].get("spacing", 0.5)
				inner_clip_half = float(TERRAIN_RES - 1) * finer_spacing * 0.5 - spacing
			pc.encode_float(0, elapsed_time)
			pc.encode_float(4, spacing)
			pc.encode_float(8, inner_clip_half)
			pc.encode_u32(16, TERRAIN_RES)
			pc.encode_u32(20, TERRAIN_RES)
			pc.encode_float(32, snap_x)
			pc.encode_float(36, snap_z)
			pc.encode_u32(48, max_vertex_counts[si])
			pc.encode_u32(52, max_index_counts[si])
			pc.encode_float(56, terrain_params["frequency"])
			pc.encode_float(60, terrain_params["amplitude"])
			pc.encode_float(64, terrain_params["ridge_strength"])
			pc.encode_float(68, terrain_params["warp_strength"])
			pc.encode_float(72, terrain_params["detail_strength"])
			pc.encode_float(76, terrain_params["base_offset"])
		"ribbon":
			pc.encode_float(0, elapsed_time)
			pc.encode_float(4, surf.get("width", 0.025))
			pc.encode_float(8, surf.get("trail_length", 4.0))
			pc.encode_u32(16, RIBBON_SEGMENTS)
			pc.encode_u32(20, RIBBON_COUNT)
			pc.encode_u32(24, max_vertex_counts[si])
			pc.encode_u32(28, max_index_counts[si])
			pc.encode_float(32, camera.global_position.x)
			pc.encode_float(36, camera.global_position.y)
			pc.encode_float(40, camera.global_position.z)
		_:
			var offset: Vector3 = surf.get("offset", Vector3.ZERO)
			pc.encode_float(0, elapsed_time)
			pc.encode_float(4, c.get("extent", 1.35))
			pc.encode_float(8, c.get("iso", 1.0))
			pc.encode_float(12, c.get("grad_step", 0.035))
			pc.encode_u32(16, MC_CELLS)
			pc.encode_u32(20, MC_CELLS)
			pc.encode_u32(24, MC_CELLS)
			pc.encode_float(32, offset.x)
			pc.encode_float(36, offset.y)
			pc.encode_float(40, offset.z)
			pc.encode_float(44, surf.get("phase", 0.0))
			pc.encode_u32(48, max_vertex_counts[si])
			pc.encode_u32(52, max_index_counts[si])
	return pc


func _bind_buffers() -> bool:
	vertex_buffers.clear()
	attribute_buffers.clear()
	index_buffers.clear()
	indirect_buffers.clear()
	max_vertex_counts.clear()
	max_index_counts.clear()
	for si in range(mesh_rd.get_surface_count()):
		var vb := mesh_rd.surface_get_vertex_buffer(si)
		var ab := mesh_rd.surface_get_attribute_buffer(si)
		var ib := mesh_rd.surface_get_index_buffer(si)
		if not vb.is_valid() or not ab.is_valid() or not ib.is_valid():
			push_error("Invalid buffers on surface %d." % si)
			return false
		var ind := rd.storage_buffer_create(INDIRECT_CMD_SIZE, PackedByteArray(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
		if not ind.is_valid():
			push_error("Failed to create indirect buffer for surface %d." % si)
			return false
		mesh_rd.surface_set_indirect_buffer(si, ind)
		vertex_buffers.append(vb)
		attribute_buffers.append(ab)
		index_buffers.append(ib)
		indirect_buffers.append(ind)
		max_vertex_counts.append(mesh_rd.surface_get_max_vertex_count(si))
		max_index_counts.append(mesh_rd.surface_get_max_index_count(si))
	return not vertex_buffers.is_empty()


func _create_uniforms() -> bool:
	uniform_sets.clear()
	var sid := shader_rids[current_case]
	for si in range(vertex_buffers.size()):
		var vu := RDUniform.new()
		vu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		vu.binding = 0
		vu.add_id(vertex_buffers[si])
		var au := RDUniform.new()
		au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		au.binding = 1
		au.add_id(attribute_buffers[si])
		var iu := RDUniform.new()
		iu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		iu.binding = 2
		iu.add_id(index_buffers[si])
		var du := RDUniform.new()
		du.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		du.binding = 3
		du.add_id(indirect_buffers[si])
		var us := rd.uniform_set_create([vu, au, iu, du], sid, 0)
		if not us.is_valid():
			push_error("uniform_set_create failed for surface %d." % si)
			return false
		uniform_sets.append(us)
	return not uniform_sets.is_empty()


func _release_surface_resources() -> void:
	if rd != null:
		for us in uniform_sets:
			if us.is_valid():
				rd.free_rid(us)
	if mesh_rd != null:
		for si in range(indirect_buffers.size()):
			if indirect_buffers[si].is_valid():
				mesh_rd.surface_set_indirect_buffer(si, RID())
	if mesh_instance != null:
		mesh_instance.mesh = null
	mesh_rd = null
	uniform_sets.clear()
	indirect_buffers.clear()
	vertex_buffers.clear()
	attribute_buffers.clear()
	index_buffers.clear()
	max_vertex_counts.clear()
	max_index_counts.clear()


func _cleanup() -> void:
	_release_surface_resources()
	if rd == null:
		return
	for pid in pipelines:
		if pid.is_valid():
			rd.free_rid(pid)
	for sid in shader_rids:
		if sid.is_valid():
			rd.free_rid(sid)
	pipelines.clear()
	shader_rids.clear()


func _reset_indirect(buf: RID) -> void:
	var data := PackedByteArray()
	data.resize(INDIRECT_CMD_SIZE)
	data.encode_u32(0, 0)
	data.encode_u32(4, 1)
	data.encode_u32(8, 0)
	data.encode_s32(12, 0)
	data.encode_u32(16, 0)
	data.encode_u32(20, 0)
	rd.buffer_update(buf, 0, INDIRECT_CMD_SIZE, data)
