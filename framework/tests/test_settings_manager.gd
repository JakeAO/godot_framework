extends GutTest
## SettingsManager clamping, no-op guards, persistence and reset behavior.
## Persistence goes through SaveSystem, so each test uses a throwaway save file.

var _original_path: String = ""
var _temp_path: String = ""


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/settings_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	SettingsManager.reset_to_defaults()


func after_each() -> void:
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func test_defaults() -> void:
	assert_almost_eq(SettingsManager.get_music_volume(), 0.8, 0.001, "default music volume")
	assert_almost_eq(SettingsManager.get_sfx_volume(), 1.0, 0.001, "default sfx volume")
	assert_eq(SettingsManager.get_language(), "en", "default language")
	assert_true(SettingsManager.is_haptics_enabled(), "haptics enabled by default")


func test_set_music_volume_clamps_and_emits() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_music_volume(1.5)
	assert_almost_eq(SettingsManager.get_music_volume(), 1.0, 0.001, "volume clamped to 1.0")
	assert_signal_emitted_with_parameters(SettingsManager, "music_volume_changed", [1.0])


func test_set_music_volume_negative_clamps_to_zero() -> void:
	SettingsManager.set_music_volume(-0.5)
	assert_almost_eq(SettingsManager.get_music_volume(), 0.0, 0.001, "volume clamped to 0.0")


func test_unchanged_setter_does_not_emit() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_sfx_volume(1.0)
	assert_signal_not_emitted(SettingsManager, "sfx_volume_changed", "setting the same value must not emit")


func test_set_language_normalizes_case_and_persists() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_language("ES")
	assert_eq(SettingsManager.get_language(), "es", "language normalized to lowercase")
	assert_signal_emitted_with_parameters(SettingsManager, "language_changed", ["es"])
	assert_eq(SaveSystem.get_value("settings", "language", ""), "es", "language persisted to save domain")


func test_set_language_empty_is_ignored() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_language("")
	assert_push_warning("ignoring empty language code", "empty language must warn")
	assert_eq(SettingsManager.get_language(), "en", "language unchanged after empty input")
	assert_signal_not_emitted(SettingsManager, "language_changed", "empty input must not emit")


func test_set_haptics_toggles_and_emits() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_haptics_enabled(false)
	assert_false(SettingsManager.is_haptics_enabled(), "haptics disabled")
	assert_signal_emitted_with_parameters(SettingsManager, "haptics_changed", [false])


func test_reset_to_defaults_restores_and_emits_all() -> void:
	SettingsManager.set_music_volume(0.2)
	SettingsManager.set_sfx_volume(0.3)
	SettingsManager.set_language("es")
	SettingsManager.set_haptics_enabled(false)
	watch_signals(SettingsManager)
	SettingsManager.reset_to_defaults()
	assert_almost_eq(SettingsManager.get_music_volume(), 0.8, 0.001, "music back to default")
	assert_almost_eq(SettingsManager.get_sfx_volume(), 1.0, 0.001, "sfx back to default")
	assert_eq(SettingsManager.get_language(), "en", "language back to default")
	assert_true(SettingsManager.is_haptics_enabled(), "haptics back to default")
	assert_signal_emitted(SettingsManager, "music_volume_changed", "reset emits music_volume_changed")
	assert_signal_emitted(SettingsManager, "sfx_volume_changed", "reset emits sfx_volume_changed")
	assert_signal_emitted(SettingsManager, "language_changed", "reset emits language_changed")
	assert_signal_emitted(SettingsManager, "haptics_changed", "reset emits haptics_changed")


func test_init_from_save_clamps_and_reads_values() -> void:
	SaveSystem.set_domain("settings", {
		"music_volume": 1.7,
		"sfx_volume": -0.4,
		"language": "es",
		"haptics_enabled": false,
	})
	SettingsManager.init_from_save()
	assert_almost_eq(SettingsManager.get_music_volume(), 1.0, 0.001, "out-of-range music volume clamped")
	assert_almost_eq(SettingsManager.get_sfx_volume(), 0.0, 0.001, "negative sfx volume clamped")
	assert_eq(SettingsManager.get_language(), "es", "language read from save")
	assert_false(SettingsManager.is_haptics_enabled(), "haptics read from save")


func test_defaults_include_new_flags() -> void:
	assert_true(SettingsManager.is_music_enabled(), "music enabled by default")
	assert_true(SettingsManager.is_sfx_enabled(), "sfx enabled by default")
	assert_true(SettingsManager.is_notifications_enabled(), "notifications on by default")
	assert_false(SettingsManager.is_reduced_vfx_enabled(), "reduced VFX off by default")


func test_set_music_enabled_toggles_and_persists() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_music_enabled(false)
	assert_false(SettingsManager.is_music_enabled(), "music disabled")
	assert_signal_emitted_with_parameters(SettingsManager, "music_enabled_changed", [false])
	assert_eq(SaveSystem.get_value("settings", "music_enabled", true), false, "flag persisted to save domain")


func test_unchanged_flag_setters_do_not_emit() -> void:
	watch_signals(SettingsManager)
	SettingsManager.set_sfx_enabled(true)
	SettingsManager.set_notifications_enabled(true)
	SettingsManager.set_reduced_vfx_enabled(false)
	assert_signal_not_emitted(SettingsManager, "sfx_enabled_changed", "same sfx value must not emit")
	assert_signal_not_emitted(SettingsManager, "notifications_changed", "same notifications value must not emit")
	assert_signal_not_emitted(SettingsManager, "reduced_vfx_changed", "same reduced-vfx value must not emit")


func test_reset_to_defaults_restores_new_flags_and_emits() -> void:
	SettingsManager.set_music_enabled(false)
	SettingsManager.set_sfx_enabled(false)
	SettingsManager.set_notifications_enabled(false)
	SettingsManager.set_reduced_vfx_enabled(true)
	watch_signals(SettingsManager)
	SettingsManager.reset_to_defaults()
	assert_true(SettingsManager.is_music_enabled(), "music back to default")
	assert_true(SettingsManager.is_sfx_enabled(), "sfx back to default")
	assert_true(SettingsManager.is_notifications_enabled(), "notifications back to default")
	assert_false(SettingsManager.is_reduced_vfx_enabled(), "reduced VFX back to default")
	assert_signal_emitted(SettingsManager, "music_enabled_changed", "reset emits music_enabled_changed")
	assert_signal_emitted(SettingsManager, "sfx_enabled_changed", "reset emits sfx_enabled_changed")
	assert_signal_emitted(SettingsManager, "notifications_changed", "reset emits notifications_changed")
	assert_signal_emitted(SettingsManager, "reduced_vfx_changed", "reset emits reduced_vfx_changed")


func test_init_from_save_reads_new_flags() -> void:
	SaveSystem.set_domain("settings", {
		"music_enabled": false,
		"sfx_enabled": false,
		"notifications_enabled": false,
		"reduced_vfx_enabled": true,
	})
	SettingsManager.init_from_save()
	assert_false(SettingsManager.is_music_enabled(), "music flag read from save")
	assert_false(SettingsManager.is_sfx_enabled(), "sfx flag read from save")
	assert_false(SettingsManager.is_notifications_enabled(), "notifications read from save")
	assert_true(SettingsManager.is_reduced_vfx_enabled(), "reduced VFX read from save")
