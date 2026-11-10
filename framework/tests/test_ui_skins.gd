extends GutTest
## UISkins role map (scripts/ui/ui_skins.gd): the only wired art role is
## DIALOG_PANEL — the button/tab artworks in assets/sprites/ui_generic/ are blob
## silhouettes that 9-slice badly onto our control sizes, so those controls stay
## on the flat theme (see DECISIONS, 2026-11-06 art review). This suite pins the
## dialog role to a variation actually registered in the generated game_theme.tres
## (drift guard), verifies dialogs carry it, and guards that screens keep the
## flat theme for buttons and tabs.

const THEME_PATH := "res://resources/theme/game_theme.tres"

var _theme: Theme
var _host: Control
var _mounted: Array[Node] = []
var _original_path: String = ""
var _temp_path: String = ""


func before_all() -> void:
	_theme = load(THEME_PATH) as Theme
	_host = Control.new()
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func before_each() -> void:
	# Redirect the save so mounting HomeScreen never triggers the FTUE
	# tutorial (fresh saves have meta.ftue_done == false).
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/skins_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	SaveSystem.set_value("meta", "ftue_done", true)


func after_each() -> void:
	for node in _mounted:
		if is_instance_valid(node):
			node.queue_free()
	_mounted.clear()
	UIManager.close_current_dialog()
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func after_all() -> void:
	# Free (not queue_free): deferred frees would still count as unfreed
	# children when GUT checks the script's tree at teardown.
	if is_instance_valid(_host):
		_host.free()


# --- Drift guard ----------------------------------------------------------------

func test_dialog_panel_points_at_a_registered_variation() -> void:
	assert_not_null(_theme, "game_theme.tres loads")
	if _theme == null:
		return
	assert_true(_theme.get_type_variation_list("Panel").has(str(UISkins.DIALOG_PANEL)), "%s is a registered Panel variation" % str(UISkins.DIALOG_PANEL))


# --- Wiring ---------------------------------------------------------------------

func test_dialog_panel_carries_dialog_skin() -> void:
	var panel := UIManager.show_text_dialog("title", "body")
	assert_not_null(panel, "dialog opened")
	if panel != null:
		assert_eq(panel.theme_type_variation, UISkins.DIALOG_PANEL, "dialog panel carries the dialog skin")
	UIManager.close_current_dialog()
	await _settle(2)


# --- Blob art stays unwired -------------------------------------------------------

func test_home_ladder_buttons_stay_flat() -> void:
	var screen := _mount(HomeScreen.new())
	for button in screen._stage_buttons:
		assert_eq(button.theme_type_variation, &"", "ladder stage buttons stay on the flat theme")


func test_social_tabs_stay_flat() -> void:
	var screen := _mount(SocialScreen.new())
	assert_eq(screen._tabs.theme_type_variation, &"", "social tabs stay on the flat theme")


func test_profile_tabs_stay_flat() -> void:
	var screen := _mount(ProfileScreen.new())
	assert_eq(screen._tabs.theme_type_variation, &"", "profile tabs stay on the flat theme")


# --- Helpers --------------------------------------------------------------------

func _mount(screen: Node) -> Node:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


func _settle(frames: int = 3) -> void:
	for i in frames:
		await get_tree().process_frame
