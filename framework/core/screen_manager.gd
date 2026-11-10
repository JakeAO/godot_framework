extends Node
## Autoload "ScreenManager". Owns the ScreenShell and swaps content screens in
## response to EventBus.navigation_requested. Screens (BaseScreen subclasses)
## are created lazily, cached per id, and REUSED — never freed — so their state
## survives navigation.

var _shell: ScreenShell = null
var _current_screen_id: StringName = &""
var _screens: Dictionary = {}


func _ready() -> void:
	EventBus.navigation_requested.connect(_on_navigation_requested)


## Mounts the shell inside `host` (full rect) and shows the home screen.
## Called once by the main scene's script.
func attach(host: Control) -> void:
	if _shell != null:
		push_warning("ScreenManager.attach() called more than once; ignoring")
		return
	if host == null:
		push_error("ScreenManager.attach() needs a valid host node")
		return
	_shell = ScreenShell.new()
	_shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(_shell)
	_show_screen(ScreenIds.HOME, &"")


func get_current_screen_id() -> StringName:
	return _current_screen_id


func get_current_screen() -> BaseScreen:
	return _screens.get(_current_screen_id, null)


func _on_navigation_requested(screen_id: StringName) -> void:
	if _shell == null:
		push_warning("ScreenManager: navigation to '%s' before attach(); ignoring" % str(screen_id))
		return
	if screen_id == _current_screen_id:
		return
	_show_screen(screen_id, _current_screen_id)


func _show_screen(screen_id: StringName, previous_screen_id: StringName) -> void:
	var screen := _get_screen(screen_id)
	if screen == null:
		push_warning("ScreenManager: no screen for '%s'; keeping current" % str(screen_id))
		return
	if _shell.content_host.get_child_count() > 0:
		_shell.content_host.remove_child(_shell.content_host.get_child(0))
	_shell.content_host.add_child(screen)
	_current_screen_id = screen_id
	EventBus.screen_changed.emit(screen_id, previous_screen_id)


func _get_screen(screen_id: StringName) -> BaseScreen:
	if _screens.has(screen_id):
		return _screens[screen_id]
	var created := _create_screen(screen_id)
	if created == null:
		return null
	_screens[screen_id] = created
	return created


func _create_screen(screen_id: StringName) -> BaseScreen:
	match screen_id:
		ScreenIds.HOME:
			return HomeScreen.new()
		ScreenIds.PROFILE:
			return ProfileScreen.new()
		ScreenIds.SOCIAL:
			return SocialScreen.new()
		ScreenIds.SPECIAL:
			return SpecialScreen.new()
		ScreenIds.SETTINGS:
			return SettingsScreen.new()
		ScreenIds.GAME:
			return GameScreen.new()
		ScreenIds.RESULTS:
			return ResultsScreen.new()
		ScreenIds.SHOP:
			return ShopScreen.new()
		ScreenIds.GIFT_PILE:
			return GiftPileScreen.new()
		_:
			push_warning("ScreenManager: no screen implementation for '%s'" % str(screen_id))
	return null
