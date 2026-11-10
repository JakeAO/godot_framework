class_name GameplayBase
extends Control
## Base class for self-contained gameplay widgets mounted inside a screen.
## Accumulates game time only while running and unpaused, so pausing freezes
## all spawn/expiry timers naturally. Emits round_ended exactly once when the
## configured duration elapses.

signal round_ended(score: int)

var is_running: bool = false
var is_paused: bool = false
var elapsed_sec: float = 0.0
## Live score for the screen HUD — the ONLY gameplay member GameScreen reads,
## so alternate mechanics need no screen changes to show a score.
var current_score: int = 0

var _round_duration_sec: float = 30.0


func start_round(duration_sec: float) -> void:
	_round_duration_sec = maxf(duration_sec, 0.1)
	elapsed_sec = 0.0
	is_paused = false
	is_running = true
	_on_round_started()


func set_paused(paused: bool) -> void:
	if is_running:
		is_paused = paused


func stop() -> void:
	is_running = false
	is_paused = false


func _process(delta: float) -> void:
	if not is_running or is_paused:
		return
	elapsed_sec += delta
	_on_game_update(delta)
	if elapsed_sec >= _round_duration_sec:
		stop()
		round_ended.emit(_final_score())


## Override to initialize round state (called at the start of every round).
func _on_round_started() -> void:
	pass


## Override to advance gameplay by one unpaused tick.
func _on_game_update(_delta: float) -> void:
	pass


## Override to report the final score when the round ends.
func _final_score() -> int:
	return 0
