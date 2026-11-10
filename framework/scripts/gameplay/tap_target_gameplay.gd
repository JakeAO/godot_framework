class_name TapTargetGameplay
extends GameplayBase
## The prototype gameplay widget: tap gold targets before they vanish.
## Spawn cadence is driven by the "target_spawn_rate" A/B experiment and target
## lifetime by the "target_lifetime_sec" remote value, so both can be tuned
## without code changes. Tapping a target scores with combo scaling (Scoring);
## letting one expire resets the chain.

const TARGET_SIZE: Vector2 = Vector2(96.0, 96.0)
const MAX_TARGETS: int = 4
const RETRY_DELAY_SEC: float = 0.1

var _chain: int = 0
var _target_lifetime_sec: float = 1.5
var _time_to_next_spawn: float = 0.0
var _targets: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


# --- Round lifecycle ------------------------------------------------------------

func _on_round_started() -> void:
	current_score = 0
	_chain = 0
	_targets.clear()
	for child in get_children():
		child.queue_free()
	_target_lifetime_sec = float(RemoteConfig.get_value("target_lifetime_sec", 1.5))
	_time_to_next_spawn = 0.0
	RemoteConfig.log_experiment_exposure("target_spawn_rate")


func _on_game_update(delta: float) -> void:
	_expire_targets()
	if _time_to_next_spawn > 0.0:
		_time_to_next_spawn -= delta
		return
	if _targets.size() < MAX_TARGETS and _spawn_target():
		_time_to_next_spawn = _roll_spawn_interval()
	else:
		_time_to_next_spawn = RETRY_DELAY_SEC


func _final_score() -> int:
	return current_score


# --- Targets --------------------------------------------------------------------

func _spawn_target() -> bool:
	var area := get_rect().size - TARGET_SIZE
	if area.x <= 0.0 or area.y <= 0.0:
		return false
	var target := ColorRect.new()
	target.size = TARGET_SIZE
	target.position = Vector2(randf_range(0.0, area.x), randf_range(0.0, area.y))
	var style := StyleBoxFlat.new()
	style.bg_color = ThemeFactory.COLOR_GOLD
	style.set_corner_radius_all(int(TARGET_SIZE.x / 2.0))
	target.add_theme_stylebox_override("normal", style)
	target.gui_input.connect(_on_target_gui_input.bind(target))
	add_child(target)
	_targets.append({"node": target, "expires_at": elapsed_sec + _target_lifetime_sec})
	return true


func _roll_spawn_interval() -> float:
	var min_sec := float(RemoteConfig.get_experiment_param("target_spawn_rate", "spawn_interval_min", 1.2))
	var max_sec := float(RemoteConfig.get_experiment_param("target_spawn_rate", "spawn_interval_max", 1.6))
	if min_sec > max_sec:
		var swapped := min_sec
		min_sec = max_sec
		max_sec = swapped
	if max_sec <= 0.0:
		return 1.4
	return randf_range(min_sec, max_sec)


func _expire_targets() -> void:
	for i in range(_targets.size() - 1, -1, -1):
		var entry: Dictionary = _targets[i]
		if elapsed_sec >= float(entry["expires_at"]):
			var node := entry["node"] as Node
			if is_instance_valid(node):
				node.queue_free()
			_targets.remove_at(i)
			_chain = 0


func _on_target_gui_input(event: InputEvent, target: ColorRect) -> void:
	if not _is_tap_pressed(event):
		return
	var index := _find_target_index(target)
	if index < 0:
		return
	_targets.remove_at(index)
	target.queue_free()
	current_score += Scoring.tap_score(_chain)
	_chain += 1


func _find_target_index(target: ColorRect) -> int:
	for i in range(_targets.size()):
		if _targets[i]["node"] == target:
			return i
	return -1


func _is_tap_pressed(event: InputEvent) -> bool:
	var touch := event as InputEventScreenTouch
	if touch != null:
		return touch.pressed
	var mouse := event as InputEventMouseButton
	if mouse != null:
		return mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed
	return false
