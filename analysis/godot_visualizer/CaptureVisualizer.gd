extends Node2D
## FFT Effect Capture Visualizer
## Loads JSON capture data and visualizes primitives frame by frame

# Capture data
var capture_data: Dictionary = {}
var frames: Array = []
var uv_trajectories: Dictionary = {}

# Playback state
var current_frame_idx: int = 0
var playing: bool = false
var play_speed: float = 1.0
var frame_accumulator: float = 0.0

# Display settings
var scale_factor: float = 2.0
var offset: Vector2 = Vector2(100, 100)
var show_wireframe: bool = true
var show_vertices: bool = true
var show_uv_labels: bool = false
var color_by_uv: bool = true

# UV colors (assigned dynamically)
var uv_colors: Dictionary = {}

# UI elements
@onready var frame_label: Label = $UI/FrameLabel
@onready var info_label: Label = $UI/InfoLabel
@onready var frame_slider: HSlider = $UI/FrameSlider


func _ready() -> void:
	# Set up default capture path
	var default_path := "res://captures/capture.json"
	if FileAccess.file_exists(default_path):
		load_capture(default_path)
	else:
		print("No capture file found at: ", default_path)
		print("Place your JSON capture in the 'captures' folder")


func load_capture(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Could not open capture file: " + path)
		return false

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("JSON parse error: " + json.get_error_message())
		return false

	capture_data = json.data
	frames = capture_data.get("frames", [])
	uv_trajectories = capture_data.get("uv_trajectories", {})

	# Assign colors to UV groups
	_assign_uv_colors()

	# Update UI
	if frame_slider:
		frame_slider.max_value = max(0, frames.size() - 1)
		frame_slider.value = 0

	current_frame_idx = 0

	print("Loaded capture: ", capture_data.get("effect_name", "unknown"))
	print("  Frames: ", frames.size())
	print("  UV groups: ", uv_trajectories.size())

	_update_info_label()
	queue_redraw()
	return true


func _assign_uv_colors() -> void:
	uv_colors.clear()
	var hue := 0.0
	var hue_step := 0.1

	for uv_key in uv_trajectories.keys():
		uv_colors[uv_key] = Color.from_hsv(hue, 0.8, 1.0)
		hue += hue_step
		if hue > 1.0:
			hue -= 1.0


func _process(delta: float) -> void:
	if playing and frames.size() > 0:
		frame_accumulator += delta * play_speed * 60.0

		while frame_accumulator >= 1.0:
			frame_accumulator -= 1.0
			current_frame_idx += 1

			if current_frame_idx >= frames.size():
				current_frame_idx = 0

		if frame_slider:
			frame_slider.value = current_frame_idx

		queue_redraw()


func _draw() -> void:
	if frames.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(10, 30),
			"No capture loaded. Press L to load a file.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		return

	# Get current frame data
	var frame_data: Dictionary = frames[current_frame_idx]
	var primitives: Array = frame_data.get("primitives", [])

	# Draw primitives
	for prim in primitives:
		_draw_primitive(prim)

	# Draw frame info
	var frame_num: int = frame_data.get("frame", current_frame_idx)
	var state_num: int = frame_data.get("state", 0)
	draw_string(ThemeDB.fallback_font, Vector2(10, 20),
		"Frame: %d / %d (state: %d)" % [current_frame_idx + 1, frames.size(), state_num],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)

	# Draw primitive count
	draw_string(ThemeDB.fallback_font, Vector2(10, 40),
		"Primitives: %d" % primitives.size(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.GRAY)


func _draw_primitive(prim: Dictionary) -> void:
	var verts: Array = prim.get("vertices", [])
	if verts.is_empty():
		return

	var prim_type: String = prim.get("type", "")
	var points: PackedVector2Array = []
	var colors: PackedColorArray = []

	# Convert vertices to screen coords
	for vert in verts:
		var pos := Vector2(vert.get("x", 0), vert.get("y", 0))
		pos = pos * scale_factor + offset
		points.append(pos)

		# Determine color
		var color: Color
		if color_by_uv:
			var uv_key := "(%d,%d)" % [vert.get("u", 0), vert.get("v", 0)]
			if uv_colors.has(uv_key):
				color = uv_colors[uv_key]
			else:
				color = _vert_color(vert)
		else:
			color = _vert_color(vert)
		colors.append(color)

	# Draw filled polygon
	if points.size() >= 3:
		if prim_type.contains("4") and points.size() >= 4:
			# Quad: draw as two triangles
			draw_colored_polygon(
				[points[0], points[1], points[2], points[3]],
				[colors[0], colors[1], colors[2], colors[3]]
			)
		else:
			# Triangle
			draw_colored_polygon(
				[points[0], points[1], points[2]],
				[colors[0], colors[1], colors[2]]
			)

	# Draw wireframe
	if show_wireframe:
		var wire_color := Color.WHITE
		wire_color.a = 0.5

		if points.size() >= 4:
			draw_polyline([points[0], points[1], points[2], points[3], points[0]],
				wire_color, 1.0)
		elif points.size() >= 3:
			draw_polyline([points[0], points[1], points[2], points[0]],
				wire_color, 1.0)

	# Draw vertices
	if show_vertices:
		for i in range(verts.size()):
			draw_circle(points[i], 3, colors[i])

			if show_uv_labels:
				var uv_text := "(%d,%d)" % [verts[i].get("u", 0), verts[i].get("v", 0)]
				draw_string(ThemeDB.fallback_font, points[i] + Vector2(5, -5),
					uv_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.WHITE)


func _vert_color(vert: Dictionary) -> Color:
	var r: float = vert.get("r", 128) / 255.0
	var g: float = vert.get("g", 128) / 255.0
	var b: float = vert.get("b", 128) / 255.0
	return Color(r, g, b)


func _update_info_label() -> void:
	if not info_label:
		return

	var text := "Effect: %s\n" % capture_data.get("effect_name", "unknown")
	text += "Frames: %d\n" % frames.size()
	text += "UV Groups: %d\n" % uv_trajectories.size()

	info_label.text = text


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				playing = not playing
				print("Playback: ", "playing" if playing else "paused")

			KEY_LEFT:
				current_frame_idx = max(0, current_frame_idx - 1)
				if frame_slider:
					frame_slider.value = current_frame_idx
				queue_redraw()

			KEY_RIGHT:
				current_frame_idx = min(frames.size() - 1, current_frame_idx + 1)
				if frame_slider:
					frame_slider.value = current_frame_idx
				queue_redraw()

			KEY_HOME:
				current_frame_idx = 0
				if frame_slider:
					frame_slider.value = 0
				queue_redraw()

			KEY_END:
				current_frame_idx = max(0, frames.size() - 1)
				if frame_slider:
					frame_slider.value = current_frame_idx
				queue_redraw()

			KEY_W:
				show_wireframe = not show_wireframe
				queue_redraw()

			KEY_V:
				show_vertices = not show_vertices
				queue_redraw()

			KEY_U:
				show_uv_labels = not show_uv_labels
				queue_redraw()

			KEY_C:
				color_by_uv = not color_by_uv
				queue_redraw()

			KEY_L:
				_open_file_dialog()

			KEY_EQUAL, KEY_KP_ADD:
				scale_factor = min(10.0, scale_factor + 0.5)
				queue_redraw()

			KEY_MINUS, KEY_KP_SUBTRACT:
				scale_factor = max(0.5, scale_factor - 0.5)
				queue_redraw()


func _open_file_dialog() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = ["*.json ; JSON Capture Files"]
	dialog.file_selected.connect(_on_file_selected)
	add_child(dialog)
	dialog.popup_centered(Vector2(800, 600))


func _on_file_selected(path: String) -> void:
	load_capture(path)


func _on_frame_slider_value_changed(value: float) -> void:
	current_frame_idx = int(value)
	queue_redraw()
