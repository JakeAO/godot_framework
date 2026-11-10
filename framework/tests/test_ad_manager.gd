extends GutTest
## AdManager state machine (idle -> loading -> loaded | error), creative
## rotation, forced failures, RemoteConfig gating and the stop/cancel path.
## A fake analytics backend captures ad_impression/ad_error events.

class FakeBackend extends IAnalyticsBackend:
	var batches: Array = []

	func flush(events: Array[Dictionary]) -> void:
		batches.append(events.duplicate(true))


var _fake: RefCounted
var _original_backends: Array = []
var _original_config_path: String = ""
var _original_cache_path: String = ""
var _original_save_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_fake = FakeBackend.new()
	_original_backends = Analytics._backends.duplicate()
	Analytics._timer.stop()
	Analytics.set_backends([_fake])


func after_all() -> void:
	AdManager.stop()
	Analytics.set_backends(_original_backends)


func before_each() -> void:
	_original_config_path = RemoteConfig._config_path
	_original_cache_path = RemoteConfig._cache_path
	_original_save_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_config_path = "user://gut_tmp/ad_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/ad_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/ad_save_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	RemoteConfig._loaded = false
	RemoteConfig._flags = {}
	RemoteConfig._values = {}
	RemoteConfig._experiments = {}
	RemoteConfig._events.clear()
	RemoteConfig._campaigns.clear()
	RemoteConfig._offers.clear()
	RemoteConfig._event_deadlines.clear()
	RemoteConfig._campaign_deadlines.clear()
	RemoteConfig._exposed_this_session = {}
	RemoteConfig._device_id = ""
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.set_cache_path(_temp_cache_path)
	_write_config(true)
	RemoteConfig.fetch()
	assert_true(RemoteConfig.is_loaded(), "stub config must load before ad tests")
	AdManager.stop()
	AdManager._creative_index = -1
	AdManager._fail_next_load = false
	AdManager.set_load_delay(0.01)
	AdManager.set_failure_rate(0.0)
	Analytics._queue.clear()
	_fake.batches.clear()


func after_each() -> void:
	AdManager.stop()
	RemoteConfig.set_config_path(_original_config_path)
	RemoteConfig.set_cache_path(_original_cache_path)
	SaveSystem.set_save_path(_original_save_path)
	var paths: Array[String] = [_temp_config_path, _temp_cache_path, _temp_save_path]
	for p in paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		var tmp := p + ".tmp"
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)


func test_start_loads_first_creative() -> void:
	watch_signals(AdManager)
	AdManager.start()
	assert_eq(AdManager.get_state(), AdManager.STATE_LOADING, "state is loading synchronously right after start")
	await wait_seconds(0.15)
	assert_eq(AdManager.get_state(), AdManager.STATE_LOADED, "banner reaches loaded state after the simulated delay")
	assert_eq(AdManager.get_current_creative().get("id", ""), "banner_volt_cola", "first creative served is volt cola")
	assert_signal_emitted_with_parameters(AdManager, "banner_state_changed", [AdManager.STATE_LOADING, {}], 0)
	assert_signal_emitted_with_parameters(AdManager, "banner_state_changed", [AdManager.STATE_LOADED, AdManager.get_current_creative()])


func test_refresh_advances_to_next_creative() -> void:
	AdManager.start()
	await wait_seconds(0.15)
	AdManager.refresh()
	await wait_seconds(0.15)
	assert_eq(AdManager.get_current_creative().get("id", ""), "banner_ironfit", "second creative served after refresh")


func test_forced_failure_lands_in_error_state_and_tracks_ad_error() -> void:
	AdManager.set_failure_rate(1.0)
	AdManager.start()
	await wait_seconds(0.2)
	assert_eq(AdManager.get_state(), AdManager.STATE_ERROR, "forced failure lands in error state")
	Analytics.flush()
	var found := false
	for batch in _fake.batches:
		for ev in batch:
			if str(ev.get("name", "")) == "ad_error":
				found = true
	assert_true(found, "ad_error event flushed to the backend")


func test_debug_fail_next_load_fails_exactly_once() -> void:
	AdManager.start()
	await wait_seconds(0.15)
	assert_eq(AdManager.get_state(), AdManager.STATE_LOADED, "baseline load succeeds at zero failure rate")
	AdManager.debug_fail_next_load()
	AdManager.refresh()
	await wait_seconds(0.15)
	assert_eq(AdManager.get_state(), AdManager.STATE_ERROR, "armed one-shot forces the next load to fail")
	AdManager.refresh()
	await wait_seconds(0.15)
	assert_eq(AdManager.get_state(), AdManager.STATE_LOADED, "the failure is one-shot: the following load recovers")


func test_watch_rewarded_succeeds_by_default_and_seam_fails_exactly_once() -> void:
	var results: Array = []
	AdManager.watch_rewarded(func(ok: bool) -> void: results.append(ok))
	assert_eq(results, [true], "mock RV completes successfully by default")
	AdManager.debug_fail_next_rewarded()
	AdManager.watch_rewarded(func(ok: bool) -> void: results.append(ok))
	assert_eq(results, [true, false], "armed seam forces the next watch to fail")
	AdManager.watch_rewarded(func(ok: bool) -> void: results.append(ok))
	assert_eq(results, [true, false, true], "the RV failure is one-shot: the following watch recovers")


func test_stop_returns_to_idle_clears_creative_and_emits() -> void:
	AdManager.start()
	await wait_seconds(0.15)
	watch_signals(AdManager)
	AdManager.stop()
	assert_eq(AdManager.get_state(), AdManager.STATE_IDLE, "stop returns the machine to idle")
	assert_eq(AdManager.get_current_creative(), {}, "creative cleared on stop")
	assert_signal_emitted_with_parameters(AdManager, "banner_state_changed", [AdManager.STATE_IDLE, {}])


func test_disabled_flag_keeps_manager_idle() -> void:
	_write_config(false)
	RemoteConfig.fetch()
	assert_false(AdManager.is_enabled(), "manager reports disabled with the flag off")
	AdManager.start()
	await wait_seconds(0.15)
	assert_eq(AdManager.get_state(), AdManager.STATE_IDLE, "disabled manager never leaves idle")


func test_load_delay_and_failure_rate_clamped_by_test_hooks() -> void:
	AdManager.set_load_delay(-5.0)
	assert_almost_eq(AdManager._load_delay_sec, 0.0, 0.001, "negative delay clamps to zero")
	AdManager.set_failure_rate(2.0)
	assert_almost_eq(AdManager._failure_rate, 1.0, 0.001, "failure rate clamps to one")


func _write_config(banner_enabled: bool) -> void:
	var src := FileAccess.open(Paths.REMOTE_CONFIG_STUB_PATH, FileAccess.READ)
	var raw := src.get_as_text()
	src.close()
	var parsed: Dictionary = JSON.parse_string(raw)
	parsed["flags"]["banner_ads_enabled"] = banner_enabled
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(parsed))
	out.close()
