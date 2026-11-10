extends GutTest
## RemoteConfig fetch/cache/flags, deterministic A/B variant picking (FNV-1a)
## and experiment exposure dedup. Each test uses throwaway config/cache/save
## files so the real user cache is never read or written.

var _original_config_path: String = ""
var _original_cache_path: String = ""
var _original_save_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	_original_config_path = RemoteConfig._config_path
	_original_cache_path = RemoteConfig._cache_path
	_original_save_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_config_path = "user://gut_tmp/rc_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/rc_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/rc_save_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	_reset_remote_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.set_cache_path(_temp_cache_path)


func after_each() -> void:
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


func test_fnv1a_known_vectors() -> void:
	assert_eq(RemoteConfig.fnv1a(""), -3750763034362895579, "empty string is the FNV offset basis")
	assert_eq(RemoteConfig.fnv1a("a"), -5808556873153909620, "single char 'a'")
	assert_eq(RemoteConfig.fnv1a("ab"), 620445648566982762, "two chars 'ab'")
	assert_eq(RemoteConfig.fnv1a("home"), 4624382957487889774, "word 'home'")
	assert_eq(RemoteConfig.fnv1a("device_123:target_spawn_rate"), 7547192324410299998, "typical experiment seed")
	assert_eq(RemoteConfig.fnv1a("héllo"), -6674344407707008800, "non-ascii input hashes over utf-8 bytes")


func test_pick_variant_is_deterministic_and_a_member() -> void:
	var variants := {"control": 50, "fast": 30, "slow": 20}
	var seed := "device_123:target_spawn_rate"
	var first := RemoteConfig.pick_variant(variants, seed)
	assert_false(first.is_empty(), "a variant was picked")
	assert_true(variants.has(first), "picked id is one of the declared variants")
	for i in range(5):
		assert_eq(RemoteConfig.pick_variant(variants, seed), first, "same seed always picks the same variant")


func test_pick_variant_edge_cases() -> void:
	assert_eq(RemoteConfig.pick_variant({}, "seed"), "", "empty variants yield empty string")
	assert_eq(RemoteConfig.pick_variant({"a": 0, "b": 0}, "seed"), "a", "zero total weight falls back to first id")
	assert_eq(RemoteConfig.pick_variant({"only": 10}, "seed"), "only", "single variant always wins")


func test_fetch_loads_flags_values_and_experiments() -> void:
	_write_config(true)
	watch_signals(EventBus)
	RemoteConfig.fetch()
	assert_true(RemoteConfig.is_loaded(), "config loaded after fetch")
	assert_eq(RemoteConfig.get_value("win_score", 0), 150, "numeric value readable from stub")
	assert_true(RemoteConfig.is_enabled("banner_ads_enabled"), "stub flag enabled")
	assert_false(RemoteConfig.is_enabled("nonexistent_flag"), "missing flag uses default false")
	assert_true(RemoteConfig.is_enabled("nonexistent_flag", true), "missing flag honors explicit default")
	assert_signal_emitted(EventBus, "config_loaded", "successful fetch emits config_loaded")
	assert_true(FileAccess.file_exists(_temp_cache_path), "fetched config written to cache")


func test_fetch_invalid_json_warns_and_stays_unloaded() -> void:
	var file := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	file.store_string("{ not json at all")
	file.close()
	watch_signals(EventBus)
	RemoteConfig.fetch()
	# Godot's JSON parser itself logs an engine error on malformed input.
	assert_engine_error("Parse JSON failed", "malformed payload trips the engine JSON logger")
	assert_push_warning("remote config invalid", "invalid payload must warn")
	assert_signal_emitted(EventBus, "config_failed", "invalid payload emits config_failed")
	assert_false(RemoteConfig.is_loaded(), "failed fetch leaves config unloaded")


func test_fetch_missing_file_warns_and_stays_unloaded() -> void:
	assert_false(FileAccess.file_exists(_temp_config_path), "test requires a missing config file")
	watch_signals(EventBus)
	RemoteConfig.fetch()
	assert_push_warning("cannot open", "missing file must warn about the open failure")
	assert_push_warning("remote config invalid", "missing file falls into the invalid branch")
	assert_signal_emitted(EventBus, "config_failed", "missing file emits config_failed")
	assert_false(RemoteConfig.is_loaded(), "failed fetch leaves config unloaded")


func test_device_id_generated_persisted_and_stable() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	var id1 := RemoteConfig._device_id
	assert_false(id1.is_empty(), "device id generated on first fetch")
	assert_eq(SaveSystem.get_value("device", "device_id", ""), id1, "device id persisted to save")
	RemoteConfig._device_id = ""
	RemoteConfig.fetch()
	assert_eq(RemoteConfig._device_id, id1, "device id restored from save on next fetch")


func test_set_device_id_empty_is_ignored() -> void:
	RemoteConfig.set_device_id("dev_manual")
	RemoteConfig.set_device_id("")
	assert_push_warning("ignoring empty device id", "empty device id must warn")
	assert_eq(RemoteConfig._device_id, "dev_manual", "device id unchanged after empty input")


func test_get_experiment_returns_stable_known_variant() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	var known := ["control", "fast", "slow"]
	var first := RemoteConfig.get_experiment("target_spawn_rate")
	assert_true(known.has(first), "experiment variant is one of the declared ones (got '%s')" % first)
	for i in range(5):
		assert_eq(RemoteConfig.get_experiment("target_spawn_rate"), first, "variant stable for the same device")


func test_get_experiment_unknown_is_empty() -> void:
	assert_eq(RemoteConfig.get_experiment("no_such_experiment"), "", "unknown experiment yields empty string")


func test_exposure_unknown_experiment_does_not_emit() -> void:
	watch_signals(EventBus)
	RemoteConfig.log_experiment_exposure("no_such_experiment")
	assert_signal_not_emitted(EventBus, "experiment_exposed", "unknown experiment must not emit exposure")


func test_exposure_dedups_within_session_and_matches_variant() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	watch_signals(EventBus)
	RemoteConfig.log_experiment_exposure("target_spawn_rate")
	RemoteConfig.log_experiment_exposure("target_spawn_rate")
	assert_signal_emit_count(EventBus, "experiment_exposed", 1, "same experiment only exposed once per session")
	var expected := RemoteConfig.get_experiment("target_spawn_rate")
	assert_signal_emitted_with_parameters(EventBus, "experiment_exposed", ["target_spawn_rate", expected])


func test_events_campaigns_and_offers_populated_from_stub() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	assert_true(RemoteConfig.get_events().size() >= 1, "stub declares at least one event (multiplayer surface)")
	assert_true(RemoteConfig.get_campaigns().size() >= 3, "stub declares at least three campaigns (solo mechanics)")
	assert_true(RemoteConfig.get_offers().size() >= 3, "stub declares at least three offers")


func test_deadline_semantics_and_active_checks() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	var now := Time.get_unix_time_from_system()
	assert_true(RemoteConfig.is_event_active("tournament_weekend"), "timed stub event is active after fetch")
	assert_eq(RemoteConfig.get_event_deadline("no_such_event"), -1, "unknown event deadline is the evergreen sentinel")
	assert_false(RemoteConfig.is_event_active("no_such_event"), "unknown event id is inactive")
	assert_eq(RemoteConfig.get_campaign_deadline("practice_bonus"), -1, "evergreen campaign has no deadline")
	assert_true(RemoteConfig.is_campaign_active("practice_bonus"), "evergreen campaign is always active")
	var xp_deadline := RemoteConfig.get_campaign_deadline("double_xp_fri")
	assert_true(xp_deadline > now, "timed campaign deadline lands in the future")
	assert_true(RemoteConfig.is_campaign_active("double_xp_fri"), "timed campaign is active inside its window")


func test_past_deadline_makes_entry_inactive() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	var now := Time.get_unix_time_from_system()
	RemoteConfig._campaign_deadlines["double_xp_fri"] = now - 10
	assert_false(RemoteConfig.is_campaign_active("double_xp_fri"), "past deadline deactivates the campaign")
	RemoteConfig._event_deadlines["tournament_weekend"] = now - 10
	assert_false(RemoteConfig.is_event_active("tournament_weekend"), "past deadline deactivates the event")


func test_set_flag_overrides_value_until_next_apply() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	assert_true(RemoteConfig.is_enabled("banner_ads_enabled"), "stub starts with the flag on")
	RemoteConfig.set_flag("banner_ads_enabled", false)
	assert_false(RemoteConfig.is_enabled("banner_ads_enabled"), "dev override flips the flag")
	RemoteConfig.set_flag("brand_new_flag", true)
	assert_true(RemoteConfig.is_enabled("brand_new_flag"), "override can introduce a new flag name")
	RemoteConfig.fetch()
	assert_true(RemoteConfig.is_enabled("banner_ads_enabled"), "refetch restores the stub value (override cleared)")
	assert_false(RemoteConfig.is_enabled("brand_new_flag"), "invented flag is gone after refetch")


func test_force_variant_pins_until_next_apply() -> void:
	_write_config(true)
	RemoteConfig.fetch()
	var natural := RemoteConfig.get_experiment("results_coin_multiplier")
	assert_true(["x1", "x2"].has(natural), "natural variant is one of the declared ones (got '%s')" % natural)
	var target := "x1" if natural == "x2" else "x2"
	RemoteConfig.force_variant("results_coin_multiplier", target)
	assert_eq(RemoteConfig.get_experiment("results_coin_multiplier"), target, "forced variant wins over bucketing")
	assert_eq(float(RemoteConfig.get_experiment_param("results_coin_multiplier", "multiplier", 0.0)), 2.0 if target == "x2" else 1.0, "params follow the forced variant")
	RemoteConfig.force_variant("no_such_experiment", "x")
	assert_push_warning("cannot force unknown experiment", "unknown experiment warns and no-ops")
	RemoteConfig.fetch()
	assert_eq(RemoteConfig.get_experiment("results_coin_multiplier"), natural, "refetch clears the pin and restores bucketing")


func _reset_remote_config() -> void:
	RemoteConfig._loaded = false
	RemoteConfig._flags = {}
	RemoteConfig._values = {}
	RemoteConfig._experiments = {}
	RemoteConfig._events.clear()
	RemoteConfig._campaigns.clear()
	RemoteConfig._offers.clear()
	RemoteConfig._event_deadlines.clear()
	RemoteConfig._campaign_deadlines.clear()
	RemoteConfig._forced_variants.clear()
	RemoteConfig._exposed_this_session = {}
	RemoteConfig._device_id = ""


func _write_config(banner_enabled: bool) -> void:
	var src := FileAccess.open(Paths.REMOTE_CONFIG_STUB_PATH, FileAccess.READ)
	var raw := src.get_as_text()
	src.close()
	var parsed: Dictionary = JSON.parse_string(raw)
	parsed["flags"]["banner_ads_enabled"] = banner_enabled
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(parsed))
	out.close()
