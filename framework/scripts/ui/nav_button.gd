class_name NavButton
extends Button
## One slot in the bottom NavBar (Profile / Social / Home / Special / Settings).
##
## Code-first widget: configure with setup(), then connect `pressed` — the
## shell routes presses to EventBus.navigation_requested(screen_id). Toggle
## mode + the "ButtonNav" theme variation give the gold selected state for free.

var screen_id: StringName = &""
var label_key: String = ""


func _ready() -> void:
	theme_type_variation = "ButtonNav"
	toggle_mode = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_text()
	LocalizationManager.locale_applied.connect(_on_locale_applied)


func _exit_tree() -> void:
	if LocalizationManager.locale_applied.is_connected(_on_locale_applied):
		LocalizationManager.locale_applied.disconnect(_on_locale_applied)


## Binds this button to a screen and its translation key.
func setup(target_screen_id: StringName, translation_key: String) -> void:
	screen_id = target_screen_id
	label_key = translation_key
	refresh_text()


## Marks this tab as the active one without triggering navigation.
func set_active(active: bool) -> void:
	button_pressed = active


func refresh_text() -> void:
	if label_key != "":
		text = tr(label_key)


func _on_locale_applied(_language_code: String) -> void:
	refresh_text()
