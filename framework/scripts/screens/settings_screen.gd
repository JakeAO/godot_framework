class_name SettingsScreen
extends BaseScreen
## Settings screen: language, music/SFX on-off toggles (sliders were replaced
## by toggles), notifications and reduced-VFX toggles, haptics toggle, legal
## and support dialogs (spawned through UIManager), and a confirmation-gated
## "Reset Save Data" action. Control state is driven by SettingsManager
## signals so it stays in sync with every other consumer.

const LANGUAGE_NAMES: Array[String] = ["English", "Español"]

var _title: Label = null
var _language_key: Label = null
var _language_option: OptionButton = null
var _music_check: CheckBox = null
var _sfx_check: CheckBox = null
var _notifications_check: CheckBox = null
var _reduced_vfx_check: CheckBox = null
var _haptics_check: CheckBox = null
var _privacy_button: Button = null
var _support_button: Button = null
var _reset_button: Button = null
var _reset_dialog: ConfirmationDialog = null


func _ready() -> void:
	super._ready()
	if not SettingsManager.music_enabled_changed.is_connected(_on_music_enabled_changed):
		SettingsManager.music_enabled_changed.connect(_on_music_enabled_changed)
	if not SettingsManager.sfx_enabled_changed.is_connected(_on_sfx_enabled_changed):
		SettingsManager.sfx_enabled_changed.connect(_on_sfx_enabled_changed)
	if not SettingsManager.notifications_changed.is_connected(_on_notifications_changed):
		SettingsManager.notifications_changed.connect(_on_notifications_changed)
	if not SettingsManager.reduced_vfx_changed.is_connected(_on_reduced_vfx_changed):
		SettingsManager.reduced_vfx_changed.connect(_on_reduced_vfx_changed)
	if not SettingsManager.language_changed.is_connected(_on_language_changed):
		SettingsManager.language_changed.connect(_on_language_changed)
	if not SettingsManager.haptics_changed.is_connected(_on_haptics_changed):
		SettingsManager.haptics_changed.connect(_on_haptics_changed)


func _exit_tree() -> void:
	if SettingsManager.music_enabled_changed.is_connected(_on_music_enabled_changed):
		SettingsManager.music_enabled_changed.disconnect(_on_music_enabled_changed)
	if SettingsManager.sfx_enabled_changed.is_connected(_on_sfx_enabled_changed):
		SettingsManager.sfx_enabled_changed.disconnect(_on_sfx_enabled_changed)
	if SettingsManager.notifications_changed.is_connected(_on_notifications_changed):
		SettingsManager.notifications_changed.disconnect(_on_notifications_changed)
	if SettingsManager.reduced_vfx_changed.is_connected(_on_reduced_vfx_changed):
		SettingsManager.reduced_vfx_changed.disconnect(_on_reduced_vfx_changed)
	if SettingsManager.language_changed.is_connected(_on_language_changed):
		SettingsManager.language_changed.disconnect(_on_language_changed)
	if SettingsManager.haptics_changed.is_connected(_on_haptics_changed):
		SettingsManager.haptics_changed.disconnect(_on_haptics_changed)
	super._exit_tree()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	# Pin to full rect: an unanchored container shrinks to minimum size at top-left.
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	vbox.add_child(_build_language_row())

	_music_check = CheckBox.new()
	_music_check.toggled.connect(_on_music_toggled)
	vbox.add_child(_music_check)

	_sfx_check = CheckBox.new()
	_sfx_check.toggled.connect(_on_sfx_toggled)
	vbox.add_child(_sfx_check)

	_notifications_check = CheckBox.new()
	_notifications_check.toggled.connect(_on_notifications_toggled)
	vbox.add_child(_notifications_check)

	_reduced_vfx_check = CheckBox.new()
	_reduced_vfx_check.toggled.connect(_on_reduced_vfx_toggled)
	vbox.add_child(_reduced_vfx_check)

	_haptics_check = CheckBox.new()
	_haptics_check.toggled.connect(_on_haptics_toggled)
	vbox.add_child(_haptics_check)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	_privacy_button = Button.new()
	_privacy_button.pressed.connect(_on_privacy_pressed)
	vbox.add_child(_privacy_button)

	_support_button = Button.new()
	_support_button.pressed.connect(_on_support_pressed)
	vbox.add_child(_support_button)

	_reset_button = Button.new()
	_reset_button.pressed.connect(_on_reset_pressed)
	vbox.add_child(_reset_button)

	_build_reset_dialog()


func _build_language_row() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	_language_key = Label.new()
	_language_key.theme_type_variation = &"LabelDim"
	hbox.add_child(_language_key)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	_language_option = OptionButton.new()
	for label in LANGUAGE_NAMES:
		_language_option.add_item(label)
	_language_option.item_selected.connect(_on_language_selected)
	hbox.add_child(_language_option)

	return hbox


func _build_reset_dialog() -> void:
	_reset_dialog = ConfirmationDialog.new()
	_reset_dialog.ok_button_text = tr("settings_reset_confirm")
	_reset_dialog.cancel_button_text = tr("settings_reset_cancel")
	_reset_dialog.confirmed.connect(_on_reset_confirmed)
	add_child(_reset_dialog)


func _apply_locale() -> void:
	_title.text = tr("settings_title")
	_language_key.text = tr("settings_language")
	_music_check.text = tr("settings_music")
	_sfx_check.text = tr("settings_sfx")
	_notifications_check.text = tr("settings_notifications")
	UIManager.attach_tooltip(_notifications_check, tr("tooltip_notifications"))
	_reduced_vfx_check.text = tr("settings_reduced_vfx")
	UIManager.attach_tooltip(_reduced_vfx_check, tr("tooltip_reduced_vfx"))
	_haptics_check.text = tr("settings_haptics")
	_privacy_button.text = tr("settings_privacy")
	_support_button.text = tr("settings_support")
	_reset_button.text = tr("settings_reset_title")
	_reset_dialog.dialog_text = tr("settings_reset_body")
	_reset_dialog.ok_button_text = tr("settings_reset_confirm")
	_reset_dialog.cancel_button_text = tr("settings_reset_cancel")
	_refresh()


func _refresh() -> void:
	var language_code := SettingsManager.get_language()
	var index := LocalizationManager.SUPPORTED_LANGUAGES.find(language_code)
	if index >= 0 and index < _language_option.item_count:
		_language_option.select(index)
	_music_check.button_pressed = SettingsManager.is_music_enabled()
	_sfx_check.button_pressed = SettingsManager.is_sfx_enabled()
	_notifications_check.button_pressed = SettingsManager.is_notifications_enabled()
	_reduced_vfx_check.button_pressed = SettingsManager.is_reduced_vfx_enabled()
	_haptics_check.button_pressed = SettingsManager.is_haptics_enabled()


# --- Input --------------------------------------------------------------------

func _on_music_toggled(enabled: bool) -> void:
	SettingsManager.set_music_enabled(enabled)


func _on_sfx_toggled(enabled: bool) -> void:
	SettingsManager.set_sfx_enabled(enabled)


func _on_notifications_toggled(enabled: bool) -> void:
	SettingsManager.set_notifications_enabled(enabled)


func _on_reduced_vfx_toggled(enabled: bool) -> void:
	SettingsManager.set_reduced_vfx_enabled(enabled)


func _on_haptics_toggled(enabled: bool) -> void:
	SettingsManager.set_haptics_enabled(enabled)


func _on_language_selected(index: int) -> void:
	if index < 0 or index >= LocalizationManager.SUPPORTED_LANGUAGES.size():
		return
	LocalizationManager.set_language(LocalizationManager.SUPPORTED_LANGUAGES[index])


func _on_music_enabled_changed(enabled: bool) -> void:
	_music_check.button_pressed = enabled


func _on_sfx_enabled_changed(enabled: bool) -> void:
	_sfx_check.button_pressed = enabled


func _on_notifications_changed(enabled: bool) -> void:
	_notifications_check.button_pressed = enabled


func _on_reduced_vfx_changed(enabled: bool) -> void:
	_reduced_vfx_check.button_pressed = enabled


func _on_language_changed(_language_code: String) -> void:
	_refresh()


func _on_haptics_changed(enabled: bool) -> void:
	_haptics_check.button_pressed = enabled


func _on_privacy_pressed() -> void:
	UIManager.show_text_dialog(tr("settings_privacy"), tr("settings_privacy_body"))


func _on_support_pressed() -> void:
	UIManager.show_text_dialog(tr("settings_support"), tr("settings_support_body"))


func _on_reset_pressed() -> void:
	_reset_dialog.popup_centered()


func _on_reset_confirmed() -> void:
	SaveSystem.clear_save()
	SettingsManager.reset_to_defaults()
	EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))
	EventBus.currency_changed.emit("coins", 0)
	EventBus.currency_changed.emit("gems", 0)
	_refresh()
