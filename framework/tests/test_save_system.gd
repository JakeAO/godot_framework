extends GutTest
## SaveSystem persistence, schema migrations, corruption quarantine and
## pre-load protection. Every test runs against a throwaway save file under
## user://gut_tmp.

var _original_path: String = ""
var _temp_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/save_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	_purge_quarantine_copies()


func after_each() -> void:
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	_remove_test_migration()


func test_missing_file_loads_fresh_defaults() -> void:
	assert_false(FileAccess.file_exists(_temp_path), "test requires a missing save file")
	var ok := SaveSystem.load_save()
	assert_true(ok, "load_save must succeed for a missing file (fresh defaults)")
	assert_eq(SaveSystem.get_value("profile", "name", ""), "Player", "fresh profile has default name")
	assert_eq(SaveSystem.get_value("profile", "level", -1), 1, "fresh profile starts at level 1")
	assert_false(SaveSystem.has_saved_game(), "no saved game exists before the first save")


func test_roundtrip_persists_values() -> void:
	SaveSystem.load_save()
	SaveSystem.set_value("profile", "coins", 777)
	SaveSystem.set_value("profile", "best_score", 4200)
	watch_signals(SaveSystem)
	var ok := SaveSystem.save_game()
	assert_true(ok, "save_game must succeed after load_save")
	assert_signal_emitted_with_parameters(SaveSystem, "save_saved", [SaveSystem.SAVE_VERSION])
	SaveSystem._data = {}
	SaveSystem.load_save()
	# Godot's JSON parser returns numbers as float, so compare with tolerance.
	assert_almost_eq(SaveSystem.get_value("profile", "coins", 0), 777, 0.001, "coins survive save + reload")
	assert_almost_eq(SaveSystem.get_value("profile", "best_score", 0), 4200, 0.001, "best_score survives save + reload")
	assert_true(SaveSystem.has_saved_game(), "saved game exists after save_game")


func test_corrupt_save_is_quarantined_and_fails() -> void:
	var file := FileAccess.open(_temp_path, FileAccess.WRITE)
	file.store_string("this is definitely not json {")
	file.close()
	var ok := SaveSystem.load_save()
	assert_false(ok, "corrupt save must fail to load")
	# Godot's JSON parser itself logs an engine error on malformed input.
	assert_engine_error("Parse JSON failed", "malformed payload trips the engine JSON logger")
	assert_push_error("quarantining corrupt save", "corrupt save must be quarantined with a logged error")
	assert_false(FileAccess.file_exists(_temp_path), "corrupt file must be moved out of the live path")
	assert_true(_find_quarantine_copy(), "a quarantine backup copy must exist in gut_tmp")


func test_future_version_save_is_rejected_and_quarantined() -> void:
	var file := FileAccess.open(_temp_path, FileAccess.WRITE)
	file.store_string('{"version": 99, "domains": {}}')
	file.close()
	var ok := SaveSystem.load_save()
	assert_false(ok, "save with a future version must be rejected")
	assert_push_error("quarantining corrupt save", "future-version save must be quarantined")


func test_old_save_migrates_forward_on_load_and_roundtrips() -> void:
	# Register the v0->v1 path for the duration of this test (production has no
	# default migrations yet; the hook itself is what's under test).
	SaveSystem.register_migration(0, 1, Callable(self, "_migrate_0_to_1"))
	var file := FileAccess.open(_temp_path, FileAccess.WRITE)
	file.store_string('{"version": 0, "domains": {"profile": {"name": "Old", "score": 555, "coins": 7}}}')
	file.close()
	watch_signals(SaveSystem)
	var ok := SaveSystem.load_save()
	_remove_test_migration()
	assert_true(ok, "old-version save must load through its migration path")
	# (no message arg: assert_signal_emitted_with_parameters' 4th param is an INT index)
	assert_signal_emitted_with_parameters(SaveSystem, "save_loaded", [SaveSystem.SAVE_VERSION])
	assert_almost_eq(float(SaveSystem.get_value("profile", "best_score", 0)), 555.0, 0.001, "legacy 'score' key migrated to best_score")
	assert_false((SaveSystem.get_domain("profile")).has("score"), "legacy key dropped by the migration")
	assert_almost_eq(float(SaveSystem.get_value("profile", "coins", 0)), 7.0, 0.001, "keys the migration doesn't touch survive")
	assert_eq(int(SaveSystem._data["version"]), SaveSystem.SAVE_VERSION, "loaded data stamped at SAVE_VERSION")
	# The migrated save must be stable: persist it and reload it.
	SaveSystem.save_game()
	SaveSystem._data = {}
	SaveSystem.load_save()
	assert_almost_eq(float(SaveSystem.get_value("profile", "best_score", 0)), 555.0, 0.001, "migrated value survives a save + reload roundtrip")


func test_old_save_without_migration_path_fails_loudly() -> void:
	var file := FileAccess.open(_temp_path, FileAccess.WRITE)
	file.store_string('{"version": 0, "domains": {}}')
	file.close()
	var ok := SaveSystem.load_save()
	assert_false(ok, "old save with no registered migration path must fail to load")
	assert_push_error("no migration path", "a missing chain is a logged error, not a silent default")


func test_save_before_load_is_blocked_when_file_exists() -> void:
	SaveSystem.load_save()
	SaveSystem.save_game()
	SaveSystem._loaded = false
	var ok := SaveSystem.save_game()
	assert_false(ok, "save before load must be refused while a file exists")
	assert_push_warning("write skipped to protect existing data", "pre-load save must warn about protection")


func test_clear_save_resets_to_defaults_and_emits() -> void:
	SaveSystem.load_save()
	SaveSystem.set_value("profile", "coins", 500)
	SaveSystem.save_game()
	watch_signals(SaveSystem)
	SaveSystem.clear_save()
	assert_signal_emitted(SaveSystem, "save_cleared", "clear_save must emit save_cleared")
	assert_eq(SaveSystem.get_value("profile", "coins", -1), 0, "coins reset to default after clear")


func test_clear_before_load_is_ignored_when_file_exists() -> void:
	SaveSystem.load_save()
	SaveSystem.save_game()
	SaveSystem._loaded = false
	watch_signals(SaveSystem)
	SaveSystem.clear_save()
	assert_push_warning("ignored to protect existing data", "pre-load clear must warn about protection")
	assert_signal_not_emitted(SaveSystem, "save_cleared", "clear before load must not emit save_cleared")


func test_get_value_missing_key_returns_default() -> void:
	SaveSystem.load_save()
	assert_eq(SaveSystem.get_value("profile", "nonexistent_key", 42), 42, "missing key falls back to default")


func test_set_domain_replaces_whole_domain() -> void:
	SaveSystem.load_save()
	SaveSystem.set_domain("meta", {"custom": true})
	assert_true(SaveSystem.get_value("meta", "custom", false) == true, "new domain value is visible")
	assert_eq(SaveSystem.get_value("meta", "created_at", -1), -1, "old keys of the replaced domain are gone")


func _purge_quarantine_copies() -> void:
	var dir := DirAccess.open("user://gut_tmp")
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.contains("corrupt"):
			DirAccess.remove_absolute("user://gut_tmp/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()


func _find_quarantine_copy() -> bool:
	var dir := DirAccess.open("user://gut_tmp")
	if dir == null:
		return false
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.contains("corrupt"):
			return true
		file_name = dir.get_next()
	dir.list_dir_end()
	return false


## Test-only v0 -> v1 migration: renames the legacy profile "score" key to
## "best_score", leaving everything else untouched.
func _migrate_0_to_1(domains: Dictionary) -> Dictionary:
	var profile: Dictionary = domains.get("profile", {})
	if profile.has("score"):
		profile["best_score"] = profile["score"]
		profile.erase("score")
	domains["profile"] = profile
	return domains


## Drops the test-only 0->1 migration so it can't leak into other tests (GUT
## runs the whole suite in one process). Idempotent.
func _remove_test_migration() -> void:
	for i in range(SaveSystem._migrations.size() - 1, -1, -1):
		var m: Dictionary = SaveSystem._migrations[i]
		if int(m["from_version"]) == 0 and int(m["to_version"]) == 1:
			SaveSystem._migrations.remove_at(i)
