extends GutTest
## ScreenManager attach, EventBus-driven navigation and the shell chrome
## (header/nav/banner) reacting to fullscreen vs normal screens.

var _host: Control


func before_all() -> void:
	_host = Control.new()
	add_child(_host)
	ScreenManager.attach(_host)


func after_all() -> void:
	if is_instance_valid(_host):
		_host.queue_free()


func test_initial_screen_is_home_with_content() -> void:
	assert_eq(ScreenManager.get_current_screen_id(), ScreenIds.HOME, "home shown right after attach")
	var shell := ScreenManager._shell
	assert_not_null(shell, "screen shell created during attach")
	assert_gt(shell.content_host.get_child_count(), 0, "home screen instance hosted in content host")


func test_navigate_to_fullscreen_hides_chrome() -> void:
	EventBus.navigation_requested.emit(ScreenIds.GAME)
	await wait_seconds(0.1)
	assert_eq(ScreenManager.get_current_screen_id(), ScreenIds.GAME, "navigation switched to game")
	var shell := ScreenManager._shell
	assert_false(shell._header_bar.visible, "player header hidden on fullscreen screens")
	assert_false(shell._nav_bar.visible, "nav bar hidden on fullscreen screens")
	assert_almost_eq(shell.content_host.anchor_top, 0.0, 0.001, "content host pinned to the full rect")


func test_navigate_back_to_normal_screen_restores_chrome() -> void:
	EventBus.navigation_requested.emit(ScreenIds.GAME)
	await wait_seconds(0.1)
	EventBus.navigation_requested.emit(ScreenIds.SETTINGS)
	await wait_seconds(0.1)
	assert_eq(ScreenManager.get_current_screen_id(), ScreenIds.SETTINGS, "navigation switched to settings")
	var shell := ScreenManager._shell
	assert_true(shell._header_bar.visible, "player header visible on normal screens")
	assert_true(shell._nav_bar.visible, "nav bar visible on normal screens")
	assert_almost_eq(shell.content_host.anchor_top, 0.16, 0.001, "content host inset below the chrome")


func test_same_id_navigation_is_noop() -> void:
	EventBus.navigation_requested.emit(ScreenIds.PROFILE)
	await wait_seconds(0.1)
	watch_signals(EventBus)
	EventBus.navigation_requested.emit(ScreenIds.PROFILE)
	await wait_seconds(0.1)
	assert_signal_emit_count(EventBus, "screen_changed", 0, "re-navigating to the current screen must not re-emit")


func test_double_attach_is_ignored_with_warning() -> void:
	var other := Control.new()
	add_child(other)
	ScreenManager.attach(other)
	assert_push_warning("more than once", "second attach must warn")
	other.queue_free()
