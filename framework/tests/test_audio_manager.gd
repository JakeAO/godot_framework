extends GutTest
## AudioManager BGM crossfade/stop, SFX pool rotation, UI sounds, music-bus
## ducking and the mobile visibility lifecycle. Settings persistence goes
## through SaveSystem, so each test uses a throwaway save file.

var _original_path: String = ""
var _temp_path: String = ""


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/audio_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	SettingsManager.reset_to_defaults()
	AudioManager.stop_bgm(0.0)
	AudioManager.unduck_music(0.0)
	AudioManager._sfx_index = 0
	await wait_seconds(0.1)


func after_each() -> void:
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func test_play_bgm_starts_and_fades_in_to_settings_volume() -> void:
	AudioManager.play_bgm(AudioManager.BGM_MENU)
	assert_eq(AudioManager._current_bgm, AudioManager.BGM_MENU, "current track set immediately")
	assert_true(AudioManager._bgm_player.playing, "bgm player started")
	await wait_seconds(0.6)
	var target := AudioManager._volume_to_db(SettingsManager.get_music_volume())
	assert_almost_eq(AudioManager._bgm_player.volume_db, target, 0.1, "bgm faded in to settings volume")


func test_play_bgm_unknown_track_warns_and_keeps_state() -> void:
	var before := AudioManager._current_bgm
	AudioManager.play_bgm("does_not_exist")
	assert_push_warning("unknown bgm track", "unknown track must warn")
	assert_eq(AudioManager._current_bgm, before, "current track unchanged after unknown request")


func test_play_same_track_does_not_restart_fade() -> void:
	AudioManager.play_bgm(AudioManager.BGM_MENU)
	await wait_seconds(0.6)
	assert_gt(AudioManager._bgm_player.volume_db, -10.0, "fully faded in before replay")
	AudioManager.play_bgm(AudioManager.BGM_MENU)
	assert_gt(AudioManager._bgm_player.volume_db, -10.0, "replaying the same track must not restart from silence")


func test_stop_bgm_clears_immediately_and_fades_out() -> void:
	AudioManager.play_bgm(AudioManager.BGM_MENU)
	await wait_seconds(0.6)
	AudioManager.stop_bgm(0.2)
	assert_eq(AudioManager._current_bgm, "", "stop clears the current track immediately")
	await wait_seconds(0.5)
	assert_false(AudioManager._bgm_player.playing, "player stopped after fade-out")


func test_play_sfx_rotates_pool_and_wraps() -> void:
	AudioManager.play_sfx(AudioManager.SFX_CLICK)
	assert_eq(AudioManager._sfx_index, 1, "pool advanced to slot 1")
	AudioManager.play_sfx(AudioManager.SFX_SUCCESS)
	assert_eq(AudioManager._sfx_index, 2, "pool advanced to slot 2")
	AudioManager.play_sfx(AudioManager.SFX_FAIL)
	assert_eq(AudioManager._sfx_index, 3, "pool advanced to slot 3")
	AudioManager.play_sfx(AudioManager.SFX_CLICK)
	assert_eq(AudioManager._sfx_index, 0, "pool wraps back to slot 0")


func test_play_sfx_unknown_warns_and_keeps_index() -> void:
	var before := AudioManager._sfx_index
	AudioManager.play_sfx("nope")
	assert_push_warning("unknown sfx", "unknown sfx must warn")
	assert_eq(AudioManager._sfx_index, before, "pool index unchanged after unknown request")


func test_play_ui_click_starts_ui_player() -> void:
	AudioManager.play_ui("click")
	assert_true(AudioManager._ui_player.playing, "ui player starts synchronously")


func test_play_ui_unknown_warns() -> void:
	AudioManager.play_ui("nope")
	assert_push_warning("unknown ui sound", "unknown ui sound must warn")


func test_duck_and_unduck_music_bus() -> void:
	var settings := SettingsManager.get_music_volume()
	AudioManager.duck_music(0.35, 0.1)
	await wait_seconds(0.4)
	var ducked := AudioManager._volume_to_db(settings * 0.35)
	assert_almost_eq(_music_bus_db(), ducked, 0.1, "music bus ducked to ratio of settings volume")
	AudioManager.unduck_music(0.1)
	await wait_seconds(0.4)
	var full := AudioManager._volume_to_db(settings)
	assert_almost_eq(_music_bus_db(), full, 0.1, "music bus restored after unduck")


func test_duck_ratio_clamped_to_full_volume() -> void:
	var settings := SettingsManager.get_music_volume()
	AudioManager.duck_music(2.0, 0.1)
	await wait_seconds(0.4)
	var full := AudioManager._volume_to_db(settings)
	assert_almost_eq(_music_bus_db(), full, 0.1, "ratio above 1.0 clamps to full settings volume")


func test_visibility_hide_stops_bgm_and_show_does_not_resume() -> void:
	AudioManager.play_bgm(AudioManager.BGM_MENU)
	await wait_seconds(0.6)
	EventBus.visibility_changed.emit(false)
	assert_eq(AudioManager._current_bgm, "", "backgrounding clears the current track")
	await wait_seconds(0.6)
	assert_false(AudioManager._bgm_player.playing, "bgm stopped after fade-out on hide")
	EventBus.visibility_changed.emit(true)
	await wait_seconds(0.6)
	assert_false(AudioManager._bgm_player.playing, "resume path is currently a no-op (documented finding)")


func _music_bus_db() -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(AudioManager.BUS_MUSIC))
