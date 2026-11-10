extends GutTest
## LocalizationManager locale switching, unsupported-language guards and the
## routing through SettingsManager (so the choice persists).

var _original_path: String = ""
var _temp_path: String = ""


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/locale_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	if SettingsManager.get_language() != "en":
		SettingsManager.set_language("en")


func after_each() -> void:
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func test_apply_locale_spanish_switches_and_translates() -> void:
	watch_signals(LocalizationManager)
	LocalizationManager.apply_locale("es")
	assert_eq(TranslationServer.get_locale(), "es", "translation server switched to es")
	assert_eq(tr("game_pause"), "Pausa", "known key translates in the new locale")
	assert_signal_emitted_with_parameters(LocalizationManager, "locale_applied", ["es"])


func test_apply_locale_english_restores_original_strings() -> void:
	LocalizationManager.apply_locale("en")
	assert_eq(TranslationServer.get_locale(), "en", "translation server switched to en")
	assert_eq(tr("game_pause"), "Pause", "known key back to the original string")


func test_apply_locale_unregistered_warns_and_keeps_current() -> void:
	LocalizationManager.apply_locale("en")
	watch_signals(LocalizationManager)
	LocalizationManager.apply_locale("de")
	assert_push_warning("no translation registered", "unregistered locale must warn")
	assert_eq(TranslationServer.get_locale(), "en", "locale unchanged after unregistered request")
	assert_signal_not_emitted(LocalizationManager, "locale_applied", "no emit for unregistered locale")


func test_set_language_unsupported_is_ignored() -> void:
	watch_signals(LocalizationManager)
	LocalizationManager.set_language("fr")
	assert_push_warning("unsupported language", "unsupported language must warn")
	assert_eq(SettingsManager.get_language(), "en", "settings unchanged after unsupported request")
	assert_eq(TranslationServer.get_locale(), "en", "locale unchanged after unsupported request")
	assert_signal_not_emitted(LocalizationManager, "locale_applied", "no emit for unsupported language")


func test_set_language_supported_routes_through_settings_and_persists() -> void:
	LocalizationManager.set_language("es")
	assert_eq(SettingsManager.get_language(), "es", "settings manager holds the new language")
	assert_eq(SaveSystem.get_value("settings", "language", ""), "es", "language persisted to save domain")
	assert_eq(TranslationServer.get_locale(), "es", "locale applied through the settings signal chain")
	assert_eq(tr("settings_title"), "Ajustes", "known key translates after routed switch")


func test_is_supported_is_case_insensitive() -> void:
	assert_true(LocalizationManager.is_supported("en"), "en is supported")
	assert_true(LocalizationManager.is_supported("ES"), "uppercase code still supported")
	assert_false(LocalizationManager.is_supported("fr"), "fr is not supported")
