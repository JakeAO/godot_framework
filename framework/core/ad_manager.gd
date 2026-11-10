extends Node
## Banner-ad system for the prototype.
##
## Simulates a banner network with a small state machine (idle -> loading ->
## loaded | error), rotating mock creatives, and an auto-refresh timer driven
## by RemoteConfig (`banner_ads_enabled`, `banner_refresh_sec`). UI subscribes
## to `banner_state_changed` instead of polling. On mobile exports with the
## remote flag `admob_enabled` set (and unit IDs configured), banner/rewarded
## traffic is delegated to the vendored AdMob plugin via AdMobBackend; every
## other environment (desktop, headless, editor) stays on the built-in mock so
## the hermetic gate never depends on native ad code.

const STATE_IDLE: String = "idle"
const STATE_LOADING: String = "loading"
const STATE_LOADED: String = "loaded"
const STATE_ERROR: String = "error"

const FLAG_ENABLED: String = "banner_ads_enabled"
const VALUE_REFRESH_SEC: String = "banner_refresh_sec"
const DEFAULT_REFRESH_SEC: float = 30.0
const MIN_REFRESH_SEC: float = 1.0
const DEFAULT_LOAD_DELAY_SEC: float = 0.6

## Live AdMob wiring (H9/H10). `admob_enabled` defaults off; unit IDs default
## to empty strings, which force the mock path even on mobile.
const FLAG_ADMOB_ENABLED: String = "admob_enabled"
const VALUE_BANNER_UNIT_ID: String = "admob_banner_unit_id"
const VALUE_REWARDED_UNIT_ID: String = "admob_rewarded_unit_id"
## Safety net: a native banner load that never calls back degrades to the
## error state instead of stalling in `loading` forever.
const BANNER_LOAD_TIMEOUT_SEC: float = 15.0
## Emitted as the creative when a live native banner is shown; BannerAdSlot
## renders it as an empty slot because the OS draws the ad over that region.
const LIVE_CREATIVE: Dictionary = {"id": "admob_live", "native": true}


class _LoadRace extends RefCounted:
	## One-shot winner-takes-all signal used to race a banner callback against
	## a timeout timer (awaiting two signals directly is not expressible).
	signal finished(winner: int, value: Variant)
	var _fired := false


	static func fire(race: _LoadRace, winner: int, value: Variant) -> void:
		if race._fired:
			return
		race._fired = true
		race.finished.emit(winner, value)

signal banner_state_changed(state: String, creative: Dictionary)

var _state: String = STATE_IDLE
var _current_creative: Dictionary = {}
var _creative_index: int = -1
var _creatives: Array[Dictionary] = [
	{"id": "banner_volt_cola", "title": "Volt Cola", "body": "Sip. Focus. Win.", "color_hex": "#4f8cff"},
	{"id": "banner_ironfit", "title": "IronFit Pro", "body": "30-day challenge starts now", "color_hex": "#3ecf8e"},
	{"id": "banner_nimbus", "title": "Nimbus Play", "body": "Stream your next favorite game", "color_hex": "#b06bff"},
]
var _running: bool = false
var _generation: int = 0
var _load_delay_sec: float = DEFAULT_LOAD_DELAY_SEC
var _failure_rate: float = 0.0
var _fail_next_load: bool = false
## One-shot seam for the rewarded-video mock (GDD §8 / TDD §3.21).
var _fail_next_rewarded: bool = false
var _timer: Timer


func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_refresh_timer_timeout)
	add_child(_timer)


# --- Public API ---------------------------------------------------------------

## Starts the banner loop. Idempotent; call once at boot (main.gd).
func start() -> void:
	if _running:
		return
	_running = true
	_refresh()


## Stops the banner loop, cancels any in-flight load and resets to idle.
func stop() -> void:
	_running = false
	_generation += 1  # invalidates any awaited refresh
	if _timer != null:
		_timer.stop()
	_current_creative = {}
	_set_state(STATE_IDLE, {})


## True when RemoteConfig currently allows banner ads.
func is_enabled() -> bool:
	return RemoteConfig.is_enabled(FLAG_ENABLED, false)


func get_state() -> String:
	return _state


func get_current_creative() -> Dictionary:
	return _current_creative.duplicate(true)


## Manually triggers a new creative (e.g. from a "refresh" UI affordance).
func refresh() -> void:
	if _running and is_enabled():
		_refresh()


## Rewarded-video watch (GDD §8 / TDD §3.21). On mobile with the live AdMob
## backend active this delegates to the native SDK (async, settles exactly
## once via `on_result`); everywhere else the mock stub always completes
## successfully and debug_fail_next_rewarded() forces the next one to fail.
## The callback carries a success bool — consumed by streak recovery, piggy
## redemption, daily-gift extras and (F3) Gift Pile.
func watch_rewarded(on_result: Callable) -> void:
	if _live_rewarded_active():
		AdMobBackend.watch_rewarded(_rewarded_unit_id(), on_result)
		return
	var ok := not _fail_next_rewarded
	_fail_next_rewarded = false
	if on_result.is_valid():
		on_result.call(ok)


# --- Test hooks ---------------------------------------------------------------

func set_load_delay(sec: float) -> void:
	_load_delay_sec = maxf(sec, 0.0)


## 0.0..1.0 chance that a simulated load fails (exercises the error state).
func set_failure_rate(rate: float) -> void:
	_failure_rate = clampf(rate, 0.0, 1.0)


## Dev/QA seam: the next NON-cancelled simulated load fails exactly once.
## (set_failure_rate cannot express this — it is read after the async await.)
func debug_fail_next_load() -> void:
	_fail_next_load = true


## Dev/QA seam: the next rewarded-video watch fails exactly once.
func debug_fail_next_rewarded() -> void:
	_fail_next_rewarded = true


# --- Internals ------------------------------------------------------------------

func _refresh() -> void:
	if not _running or not is_enabled():
		return
	_generation += 1  # supersedes any earlier in-flight refresh
	var gen := _generation
	var live := _live_banner_active()
	_set_state(STATE_LOADING, {})
	var success := false
	if live:
		success = await _load_live_banner(gen)
	else:
		await _simulate_network_load()
		if gen != _generation or not _running:
			return  # cancelled by stop() or a newer refresh
		success = not (_fail_next_load or randf() < _failure_rate)
		_fail_next_load = false
	if gen != _generation or not _running:
		return  # cancelled by stop() or a newer refresh
	if not success:
		Analytics.track("ad_error", {"source": "banner"})
		_set_state(STATE_ERROR, {})
	else:
		if live:
			_current_creative = LIVE_CREATIVE.duplicate(true)
		else:
			_advance_creative()
		Analytics.track("ad_impression", {
			"creative_id": str(_current_creative.get("id", "")),
			"source": "banner",
		})
		_set_state(STATE_LOADED, _current_creative)
	_schedule_next_refresh()


## Stand-in for the ad SDK's async request. Awaits a short delay so the
## loading state is observable in both editor and tests.
func _simulate_network_load() -> void:
	await get_tree().create_timer(_load_delay_sec).timeout


# --- Live AdMob backend (H9/H10) ----------------------------------------------

## True on mobile exports with the remote flag set; desktop/headless always
## stay on the mock so the hermetic gate is native-code free.
func _real_backend_active() -> bool:
	if not AdMobBackend.is_supported_platform():
		return false
	return RemoteConfig.is_enabled(FLAG_ADMOB_ENABLED, false)


func _live_banner_active() -> bool:
	return _real_backend_active() and not _banner_unit_id().is_empty()


func _live_rewarded_active() -> bool:
	return _real_backend_active() and not _rewarded_unit_id().is_empty()


func _banner_unit_id() -> String:
	var configured: Variant = RemoteConfig.get_value(VALUE_BANNER_UNIT_ID, "")
	return str(configured)


func _rewarded_unit_id() -> String:
	var configured: Variant = RemoteConfig.get_value(VALUE_REWARDED_UNIT_ID, "")
	return str(configured)


## Awaits a live banner load, racing it against BANNER_LOAD_TIMEOUT_SEC so a
## silent native SDK degrades to the error state instead of stalling.
func _load_live_banner(gen: int) -> bool:
	var race := _LoadRace.new()
	var bridge := AdMobBackend.load_banner(_banner_unit_id())
	bridge.completed.connect(func(ok: bool) -> void: _LoadRace.fire(race, 0, ok))
	get_tree().create_timer(BANNER_LOAD_TIMEOUT_SEC).timeout.connect(
		func() -> void: _LoadRace.fire(race, 1, false)
	)
	var result: Array = await race.finished
	if gen != _generation or not _running:
		return false
	return int(result[0]) == 0 and bool(result[1])


func _advance_creative() -> void:
	_creative_index = (_creative_index + 1) % _creatives.size()
	_current_creative = _creatives[_creative_index].duplicate(true)


func _schedule_next_refresh() -> void:
	if not _running or _timer == null:
		return
	var wait_sec := DEFAULT_REFRESH_SEC
	var configured: Variant = RemoteConfig.get_value(VALUE_REFRESH_SEC, DEFAULT_REFRESH_SEC)
	if typeof(configured) == TYPE_INT or typeof(configured) == TYPE_FLOAT:
		wait_sec = float(configured)
	_timer.wait_time = maxf(wait_sec, MIN_REFRESH_SEC)
	_timer.start()


func _on_refresh_timer_timeout() -> void:
	_refresh()


func _set_state(new_state: String, creative: Dictionary) -> void:
	_state = new_state
	banner_state_changed.emit(_state, creative)
