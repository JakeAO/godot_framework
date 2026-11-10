extends GutTest


func test_autoloads_available() -> void:
	assert_not_null(EventBus, "EventBus autoload should be present")
	assert_not_null(SaveSystem, "SaveSystem autoload should be present")
	assert_not_null(SettingsManager, "SettingsManager autoload should be present")
	assert_not_null(LocalizationManager, "LocalizationManager autoload should be present")
	assert_not_null(Analytics, "Analytics autoload should be present")
	assert_not_null(RemoteConfig, "RemoteConfig autoload should be present")
	assert_not_null(AudioManager, "AudioManager autoload should be present")
	assert_not_null(AdManager, "AdManager autoload should be present")
	assert_not_null(ScreenManager, "ScreenManager autoload should be present")


func test_screen_ids_available() -> void:
	assert_eq(str(ScreenIds.HOME), "home")
	assert_true(ScreenIds.is_fullscreen(ScreenIds.GAME))
