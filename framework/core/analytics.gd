extends Node
## Event analytics with pluggable backends, batching and session tracking.
##
## - track() queues events; batches flush on timer, size threshold, or manually.
## - Sessions start/stop automatically with app visibility (mobile lifecycle).
## - Screen views are captured automatically from EventBus.screen_changed.
## - Experiment exposures are logged when RemoteConfig assigns variants.

const FLUSH_INTERVAL_SEC: float = 10.0
const FLUSH_BATCH_SIZE: int = 25
const MAX_QUEUE_SIZE: int = 500

signal flushed(event_count: int)

var _backends: Array[IAnalyticsBackend] = []
var _queue: Array[Dictionary] = []
var _timer: Timer
var _session_id: String = ""
var _session_start_unix: int = 0
var _flushing: bool = false


func _ready() -> void:
	_backends = [
		ConsoleAnalyticsBackend.new(),
		FileAnalyticsBackend.new(),
		NakamaAnalyticsBackend.new(),
	]
	_timer = Timer.new()
	_timer.wait_time = FLUSH_INTERVAL_SEC
	_timer.timeout.connect(_on_flush_timer_timeout)
	add_child(_timer)
	_timer.start()

	EventBus.screen_changed.connect(_on_screen_changed)
	EventBus.experiment_exposed.connect(_on_experiment_exposed)


# --- Public API ---------------------------------------------------------------

func set_backends(backends: Array) -> void:
	_backends.clear()
	for b in backends:
		if b is IAnalyticsBackend:
			_backends.append(b)
		else:
			push_warning("Analytics: ignoring backend of type %s (not IAnalyticsBackend)" % typeof(b))


func track(event_name: String, properties: Dictionary = {}) -> void:
	if event_name.is_empty():
		push_warning("Analytics: ignoring empty event name")
		return
	var event := {
		"name": event_name,
		"ts": int(Time.get_unix_time_from_system()),
		"session_id": _session_id,
		"properties": properties.duplicate(true),
	}
	if _queue.size() >= MAX_QUEUE_SIZE:
		flush()  # backpressure: drop the oldest by flushing first
		_queue.pop_front()
	_queue.append(event)
	if _queue.size() >= FLUSH_BATCH_SIZE:
		flush()


func flush() -> void:
	if _flushing or _queue.is_empty():
		return
	_flushing = true
	var batch := _queue.duplicate()
	_queue.clear()
	for b in _backends:
		b.flush(batch)
	flushed.emit(batch.size())
	_flushing = false


# --- Session lifecycle ----------------------------------------------------------

func start_session() -> void:
	if not _session_id.is_empty():
		return
	_session_id = _generate_session_id()
	_session_start_unix = int(Time.get_unix_time_from_system())
	EventBus.session_started.emit(_session_id)
	track("session_start", {"source": "app_launch"})


func end_session() -> void:
	if _session_id.is_empty():
		return
	var duration_sec := int(Time.get_unix_time_from_system()) - _session_start_unix
	track("session_end", {"duration_sec": duration_sec})
	flush()
	EventBus.session_ended.emit(_session_id)
	_session_id = ""


func get_session_id() -> String:
	return _session_id


# --- Internals --------------------------------------------------------------------

## The Nakama sink is always attached (TDD §3.17): it is inert in mock mode
## (no real-mode OnlineService), so the gate stays hermetic with no extra wiring.


func _on_screen_changed(screen_id: StringName, _previous: StringName) -> void:
	track("screen_view", {"screen": str(screen_id)})


func _on_experiment_exposed(experiment_name: String, variant_id: String) -> void:
	track("experiment_exposure", {
		"experiment": experiment_name,
		"variant": variant_id,
	})


func _on_flush_timer_timeout() -> void:
	flush()


func _generate_session_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%d_%08x" % [int(Time.get_unix_time_from_system()), rng.randi() & 0xFFFFFFFF]
