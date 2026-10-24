extends Node3D

const PORT = 9999
const ADDRESS = "127.0.0.1"
const VOTING_DURATION = 30.0 # GDD Section 10: 30s voting

@onready var host_btn = $CanvasLayer/VBoxContainer/HostButton
@onready var join_btn = $CanvasLayer/VBoxContainer/JoinButton
@onready var ui = $CanvasLayer
@onready var meeting_ui = $CanvasLayer/MeetingUI
@onready var timer_label = $CanvasLayer/MeetingUI/TimerLabel
@onready var vote_container = $CanvasLayer/MeetingUI/VoteButtonsContainer
@onready var skip_btn = $CanvasLayer/MeetingUI/SkipVoteButton
@onready var result_label = $CanvasLayer/MeetingUI/ResultLabel

var player_scene = preload("res://player.tscn")
var corpse_scene = preload("res://corpse.tscn")

var players: Array[int] = []
var votes: Dictionary = {} # voter_id -> target_id (0 = skip)
var is_voting_active: bool = false
var voting_timer: float = 0.0

func _ready() -> void:
	host_btn.pressed.connect(_on_host_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	skip_btn.pressed.connect(func(): _on_vote_selected(0))

func _process(delta: float) -> void:
	DisplayServer.window_set_title("Dark Station - FPS: " + str(Engine.get_frames_per_second()))
	
	if multiplayer.is_server() and is_voting_active:
		voting_timer -= delta
		update_voting_timer.rpc(ceil(voting_timer))
		if voting_timer <= 0.0:
			end_voting()

func _on_host_pressed() -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(PORT)
	if error != OK:
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_add_player)
	multiplayer.peer_disconnected.connect(_remove_player)
	
	ui.get_node("VBoxContainer").hide()
	_add_player(1)

func _on_join_pressed() -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(ADDRESS, PORT)
	if error != OK:
		return
	multiplayer.multiplayer_peer = peer
	ui.get_node("VBoxContainer").hide()

func _add_player(id: int) -> void:
	players.append(id)
	var player = player_scene.instantiate()
	player.name = str(id)
	player.position = Vector3(randf_range(-3, 3), 1.5, randf_range(-3, 3))
	add_child(player)

	if multiplayer.is_server() and players.size() >= 2:
		assign_test_roles.rpc()

@rpc("call_local", "reliable")
func assign_test_roles() -> void:
	var host_player = get_node_or_null("1")
	if host_player:
		host_player.set_role(host_player.Role.SABOTEUR)
	for id in players:
		if id != 1:
			var client_player = get_node_or_null(str(id))
			if client_player:
				client_player.set_role(client_player.Role.CREWMATE)

func spawn_corpse(corpse_pos: Vector3, corpse_rot: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var corpse = corpse_scene.instantiate()
	corpse.position = corpse_pos
	corpse.rotation = corpse_rot
	corpse.add_to_group("corpses") # Explicitly ensures group assignment in code
	add_child(corpse, true)

@rpc("any_peer", "call_local", "reliable")
func request_meeting_server(_reporter_id: int, _reason: String) -> void:
	if not multiplayer.is_server() or is_voting_active:
		return
	
	# Clean up any corpses on the floor when meeting begins
	for child in get_children():
		if "Corpse" in child.name or child.is_in_group("corpses"):
			child.queue_free()

	# Teleport living players to circle podiums
	var alive_players: Array[int] = []
	for id in players:
		var p = get_node_or_null(str(id))
		if p and not p.is_dead:
			alive_players.append(id)

	var count = alive_players.size()
	for i in range(count):
		var id = alive_players[i]
		var p = get_node_or_null(str(id))
		var angle = (float(i) / float(count)) * TAU
		var podium_pos = Vector3(cos(angle) * 4.0, 1.5, sin(angle) * 4.0)
		p.set_meeting_state.rpc(true, podium_pos)

	votes.clear()
	is_voting_active = true
	voting_timer = VOTING_DURATION
	start_meeting_client.rpc(alive_players)

@rpc("call_local", "reliable")
func start_meeting_client(alive_players: Array) -> void:
	meeting_ui.show()
	result_label.text = ""
	
	# Clear previous vote buttons
	for child in vote_container.get_children():
		child.queue_free()

	# Create a vote button for each alive player
	var my_id = multiplayer.get_unique_id()
	var my_player = get_node_or_null(str(my_id))
	var can_vote = my_player and not my_player.is_dead

	for id in alive_players:
		var btn = Button.new()
		btn.text = "Player " + str(id)
		btn.disabled = not can_vote
		btn.pressed.connect(func(): _on_vote_selected(id))
		vote_container.add_child(btn)

	skip_btn.disabled = not can_vote

func _on_vote_selected(target_id: int) -> void:
	# Disable UI buttons once local vote is submitted
	for child in vote_container.get_children():
		if child is Button: child.disabled = true
	skip_btn.disabled = true
	submit_vote_server.rpc_id(1, multiplayer.get_unique_id(), target_id)

@rpc("any_peer", "call_local", "reliable")
func submit_vote_server(voter_id: int, target_id: int) -> void:
	if not multiplayer.is_server() or not is_voting_active:
		return
	votes[voter_id] = target_id
	
	# If all alive players have voted, end discussion immediately
	var alive_count = 0
	for id in players:
		var p = get_node_or_null(str(id))
		if p and not p.is_dead: alive_count += 1
		
	if votes.size() >= alive_count:
		end_voting()

@rpc("call_local", "reliable")
func update_voting_timer(time_left: float) -> void:
	timer_label.text = "Voting Time: " + str(time_left) + "s"

func end_voting() -> void:
	is_voting_active = false
	
	# Tally votes (0 = skip) - GDD Section 10 Rule 4: Plurality ejects, tie/skip ejects nobody
	var tally: Dictionary = {}
	for voter in votes:
		var target = votes[voter]
		tally[target] = tally.get(target, 0) + 1

	var highest_votes = 0
	var ejected_id = 0
	var is_tie = false

	for target in tally:
		var count = tally[target]
		if count > highest_votes:
			highest_votes = count
			ejected_id = target
			is_tie = false
		elif count == highest_votes and count > 0:
			is_tie = true

	var announcement = ""
	if is_tie or ejected_id == 0:
		announcement = "No one was ejected (Skipped or Tied)."
	else:
		announcement = "Player " + str(ejected_id) + " was ejected."
		var ejected_player = get_node_or_null(str(ejected_id))
		if ejected_player:
			ejected_player.die.rpc()

	display_meeting_result.rpc(announcement)
	await get_tree().create_timer(4.0).timeout
	reset_round.rpc()

@rpc("call_local", "reliable")
func display_meeting_result(result_text: String) -> void:
	result_label.text = result_text

@rpc("call_local", "reliable")
func reset_round() -> void:
	meeting_ui.hide()
	# GDD Section 10 Rule 5: Everyone respawns at the Hub, 20s grace period
	for id in players:
		var p = get_node_or_null(str(id))
		if p:
			var hub_pos = Vector3(randf_range(-3, 3), 1.5, randf_range(-3, 3))
			p.set_meeting_state(false, hub_pos)

func _remove_player(id: int) -> void:
	players.erase(id)
	var p = get_node_or_null(str(id))
	if p: p.queue_free()
