extends Camera3D

var mouse_sensitivity := 0.002
var move_speed := 5.0
var fast_multiplier := 3.0
var _yaw := 0.0
var _pitch := 0.0
var _captured := false


func _ready() -> void:
	_sync_angles()


func reset_to(pos: Vector3, target: Vector3) -> void:
	position = pos
	look_at(target, Vector3.UP)
	_sync_angles()


func _sync_angles() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_captured = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _captured else Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -PI * 0.49, PI * 0.49)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	if not _captured:
		return
	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= fast_multiplier
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		dir.y -= 1.0
	if dir != Vector3.ZERO:
		position += basis * dir.normalized() * speed * delta
