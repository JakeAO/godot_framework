extends GutTest
## Ad backend gating (H9/H10): on desktop/headless the live AdMob path must be
## unreachable no matter what remote config says, so the hermetic gate stays
## native-code free. Also covers the LIVE_CREATIVE contract consumed by
## BannerAdSlot and the default-empty unit-ID accessors.


var _original_config_path: String = ""
var _original_cache_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""


func before_each() -> void:
	_original_config_path = RemoteConfig._config_path
	_original_cache_path = RemoteConfig._cache_path
	var stamp := Time.get_ticks_usec()
	_temp_config_path = "user://gut_tmp/adgate_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/adgate_cache_%d.json" % (stamp + 1)
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
	_write_config(true, true, "ca-app-pub-test-banner", "ca-app-pub-test-rv")
	RemoteConfig.fetch()
	assert_true(RemoteConfig.is_loaded(), "stub config must load before gate tests")
	AdManager.stop()
	AdManager._creative_index = -1
	AdManager._fail_next_load = false
	AdManager.set_load_delay(0.01)
	AdManager.set_failure_rate(0.0)


func after_each() -> void:
	AdManager.stop()
	RemoteConfig.set_config_path(_original_config_path)
	RemoteConfig.set_cache_path(_original_cache_path)
	var paths: Array[String] = [_temp_config_path, _temp_cache_path]
	for p in paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		var tmp := p + ".tmp"
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)


func test_platform_guard_blocks_live_backend_on_desktop() -> void:
	assert_false(AdMobBackend.is_supported_platform(), "headless/desktop is not a supported AdMob platform")
	assert_false(AdManager._live_banner_active(), "banner live path is unreachable on desktop even with flag + unit ID set")
	assert_false(AdManager._live_rewarded_active(), "rewarded live path is unreachable on desktop even with flag + unit ID set")


func test_mock_path_serves_mock_creative_with_admob_flag_on() -> void:
	AdManager.start()
	await wait_seconds(0.15)
	assert_eq(AdManager.get_state(), AdManager.STATE_LOADED, "banner still loads in mock mode")
	assert_eq(AdManager.get_current_creative().get("id", ""), "banner_volt_cola", "the mock creative is served, not the live placeholder")


func test_watch_rewarded_stays_mock_with_admob_flag_on() -> void:
	var results: Array = []
	AdManager.watch_rewarded(func(ok: bool) -> void: results.append(ok))
	assert_eq(results, [true], "mock RV settles synchronously and successfully on desktop")


func test_unit_id_accessors_read_remote_config() -> void:
	assert_eq(AdManager._banner_unit_id(), "ca-app-pub-test-banner", "banner unit ID comes from remote config")
	assert_eq(AdManager._rewarded_unit_id(), "ca-app-pub-test-rv", "rewarded unit ID comes from remote config")
	_write_config(true, false, "", "")
	RemoteConfig.fetch()
	assert_eq(AdManager._banner_unit_id(), "", "empty unit IDs force the mock path")
	assert_false(RemoteConfig.is_enabled(AdManager.FLAG_ADMOB_ENABLED, false), "admob flag reads back as disabled")


func test_live_creative_contract_for_banner_slot() -> void:
	assert_eq(str(AdManager.LIVE_CREATIVE.get("id", "")), "admob_live", "live creative carries a stable id for analytics")
	assert_true(bool(AdManager.LIVE_CREATIVE.get("native", false)), "live creative is flagged native so the slot paints nothing")


func test_banner_slot_renders_native_creative_as_empty() -> void:
	var slot := BannerAdSlot.new()
	add_child(slot)
	slot._render_creative(AdManager.LIVE_CREATIVE.duplicate(true))
	assert_eq(slot._title_label.text, "", "native creative leaves the title empty")
	assert_eq(slot._body_label.text, "", "native creative leaves the body empty")
	assert_false(slot._panel.has_theme_stylebox_override("panel"), "native creative clears the painted background")
	remove_child(slot)
	slot.free()


func _write_config(banner_enabled: bool, admob_enabled: bool, banner_unit: String, rewarded_unit: String) -> void:
	var src := FileAccess.open(Paths.REMOTE_CONFIG_STUB_PATH, FileAccess.READ)
	var raw := src.get_as_text()
	src.close()
	var parsed: Dictionary = JSON.parse_string(raw)
	parsed["flags"]["banner_ads_enabled"] = banner_enabled
	parsed["flags"]["admob_enabled"] = admob_enabled
	parsed["values"]["admob_banner_unit_id"] = banner_unit
	parsed["values"]["admob_rewarded_unit_id"] = rewarded_unit
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(parsed))
	out.close()
