extends CharacterBody3D

enum Role { CREWMATE, SABOTEUR }

const SPEED = 4.5
const JUMP_VELOCITY = 4.0
const MOUSE_SENSITIVITY = 0.002
const BATTERY_DRAIN_RATE = 100.0 / 90.0
const KILL_COOLDOWN_TIME = 40.0 # From GDD Section 8

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/Camera3D/Flashlight
@onready var kill_ray: RayCast3D = $Head/Camera3D/KillRay
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

var battery: float = 100.0
var is_dead: bool = false
var is_locked: bool = false # Frozen during meetings
var current_role: Role = Role.CREWMATE
var kill_cooldown: float = 0.0

@export var flashlight_on: bool = false:
	set(value):
		flashlight_on = value
		if flashlight:
			flashlight.visible = flashlight_on

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _ready() -> void:
	kill_ray.add_exception(self)
	if is_multiplayer_authority():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		camera.current = true
		if mesh:
			mesh.visible = false
	else:
		camera.current = false
		if flashlight:
			flashlight.shadow_enabled = false

func set_role(new_role: Role) -> void:
	current_role = new_role
	if is_multiplayer_authority():
		if current_role == Role.SABOTEUR:
			print("YOU ARE THE SABOTEUR. Strike cooldown: 40s.")
			kill_cooldown = 10.0 # Initial match start grace period
		else:
			print("YOU ARE A CREWMATE. Report corpses and stay alive.")

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or is_locked:
		return

	# Re-capture mouse
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			get_viewport().set_input_as_handled()

	# Mouse look
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		head.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-89), deg_to_rad(89))

	# Flashlight toggle
	if event.is_action_pressed("flashlight_toggle") and not is_dead:
		if battery > 0.0:
			flashlight_on = !flashlight_on

	# Kill action (Q)
	if event is InputEventKey and event.physical_keycode == KEY_Q and event.is_pressed() and not event.is_echo():
		if current_role == Role.SABOTEUR and kill_cooldown <= 0.0 and not is_dead:
			_attempt_kill()

	# Report body action (E)
	if event.is_action_pressed("interact") and not is_dead:
		_check_for_body_report()

	# Free cursor
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority() or is_locked:
		return

	if current_role == Role.SABOTEUR and kill_cooldown > 0.0:
		kill_cooldown = max(0.0, kill_cooldown - delta)

	if is_dead:
		# Ghost free flight
		var fly_dir := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W): fly_dir -= head.global_transform.basis.z
		if Input.is_physical_key_pressed(KEY_S): fly_dir += head.global_transform.basis.z
		if Input.is_physical_key_pressed(KEY_A): fly_dir -= head.global_transform.basis.x
		if Input.is_physical_key_pressed(KEY_D): fly_dir += head.global_transform.basis.x
		if Input.is_physical_key_pressed(KEY_SPACE): fly_dir += Vector3.UP
		if Input.is_physical_key_pressed(KEY_CTRL): fly_dir -= Vector3.UP
		velocity = fly_dir.normalized() * SPEED * 1.5
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_action_pressed("ui_up"): input_dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_action_pressed("ui_down"): input_dir.y += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"): input_dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"): input_dir.x += 1.0
	input_dir = input_dir.normalized()

	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()

	if flashlight_on:
		battery = max(0.0, battery - BATTERY_DRAIN_RATE * delta)
		if battery <= 0.0:
			flashlight_on = false

func _attempt_kill() -> void:
	if kill_ray.is_colliding():
		var collider = kill_ray.get_collider()
		if collider is CharacterBody3D and collider != self and not collider.is_dead:
			var victim_id = collider.name.to_int()
			request_kill_server.rpc_id(1, victim_id)

func _check_for_body_report() -> void:
	# Find all corpses via group, with child-node fallback
	var corpses = get_tree().get_nodes_in_group("corpses")
	if corpses.is_empty():
		for child in get_parent().get_children():
			if "Corpse" in child.name or child.is_in_group("corpses"):
				corpses.append(child)

	print("Total corpses detected in scene: ", corpses.size())

	for corpse in corpses:
		var dist = global_position.distance_to(corpse.global_position)
		print("Distance to corpse: ", dist)
		# 3.5 meter radius to easily cover player height (1.5m) and capsule width
		if dist <= 3.5:
			print("Corpse in range! Triggering emergency meeting...")
			get_parent().request_meeting_server.rpc_id(1, name.to_int(), "Body Reported")
			return

	print("No corpses within 3.5 meters to report.")
	for corpse in corpses:
		# Check distance in 3D (within 3.0 meters)
		if global_position.distance_to(corpse.global_position) <= 3.0:
			print("Corpse found within range! Requesting meeting...")
			get_parent().request_meeting_server.rpc_id(1, name.to_int(), "Body Reported")
			return
	print("No corpses within 3 meters to report.")

@rpc("any_peer", "call_local", "reliable")
func request_kill_server(victim_id: int) -> void:
	if not multiplayer.is_server():
		return
	var victim = get_parent().get_node_or_null(str(victim_id))
	if victim and not victim.is_dead:
		kill_confirmed.rpc_id(multiplayer.get_remote_sender_id())
		get_parent().spawn_corpse(victim.global_position, victim.global_rotation)
		victim.die.rpc()

@rpc("call_local", "reliable")
func kill_confirmed() -> void:
	kill_cooldown = KILL_COOLDOWN_TIME
	print("Strike successful! 40s cooldown started.")

@rpc("call_local", "reliable")
func die() -> void:
	is_dead = true
	flashlight_on = false
	if flashlight:
		flashlight.visible = false
	if collision_shape:
		collision_shape.disabled = true
	if mesh:
		mesh.visible = false
	if is_multiplayer_authority():
		print("YOU WERE KILLED. You are now a Spectator Ghost.")

@rpc("call_local", "reliable")
func set_meeting_state(locked: bool, podium_pos: Vector3) -> void:
	is_locked = locked
	global_position = podium_pos
	velocity = Vector3.ZERO
	if is_multiplayer_authority():
		if locked:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			# GDD Section 10 Reset: kill cooldowns drop to 20s
			if current_role == Role.SABOTEUR:
				kill_cooldown = 20.0
