class_name PlayerInfoHeader
extends Control
## Top bar of the shared screen shell: gems (left), player icon + level
## (center) and coins (right). All three are tappable (H9): gems → Special
## screen, profile block → Profile screen, coins → Shop.
##
## Reads the "profile" save domain once and then stays in sync through
## EventBus signals (profile_updated / currency_changed), so any system that
## mutates the profile keeps the header live without touching it directly.

const PROFILE_DOMAIN: String = "profile"
const AVATAR_SIZE: int = 48
const CAPTION_FONT_SIZE: int = 12

var _profile: Dictionary = {}
var _avatar_label: Label
var _name_label: Label
var _level_label: Label
## Tappable (TDD §3.20): opens the Shop. Flat/transparent at rest so the
## header looks unchanged; gold text matches the old LabelGold value label.
var _coins_button: Button
## H9: tappable — gems are the prototype-specific currency, so the gems widget
## opens the Special screen (same flat-ButtonNav treatment as coins).
var _gems_button: Button
## H9: the center avatar/name/level block is one tap target → Profile screen.
var _center_box: HBoxContainer


func _ready() -> void:
	_build_layout()
	_profile = SaveSystem.get_domain(PROFILE_DOMAIN)
	_refresh_from_profile()
	LocalizationManager.locale_applied.connect(_on_locale_applied)
	EventBus.profile_updated.connect(_on_profile_updated)
	EventBus.currency_changed.connect(_on_currency_changed)


func _exit_tree() -> void:
	if LocalizationManager.locale_applied.is_connected(_on_locale_applied):
		LocalizationManager.locale_applied.disconnect(_on_locale_applied)
	if EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.disconnect(_on_profile_updated)
	if EventBus.currency_changed.is_connected(_on_currency_changed):
		EventBus.currency_changed.disconnect(_on_currency_changed)


# --- Layout -------------------------------------------------------------------

func _build_layout() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	add_child(root)

	_gems_button = _build_gems_button(root)

	var spacer_left := Control.new()
	spacer_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(spacer_left)

	_center_box = HBoxContainer.new()
	_center_box.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	_center_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# H9: the whole center block is one tap target (Profile screen). Children
	# must IGNORE so taps fall through to this container.
	_center_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_center_box.gui_input.connect(_on_profile_tapped)
	root.add_child(_center_box)

	var avatar := Panel.new()
	avatar.theme_type_variation = "PanelAvatar"
	avatar.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center_box.add_child(avatar)

	_avatar_label = Label.new()
	_avatar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_avatar_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar.add_child(_avatar_label)

	var identity := VBoxContainer.new()
	identity.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center_box.add_child(identity)

	_name_label = Label.new()
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	identity.add_child(_name_label)

	_level_label = Label.new()
	_level_label.theme_type_variation = "LabelDim"
	_level_label.add_theme_font_size_override("font_size", CAPTION_FONT_SIZE)
	_level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	identity.add_child(_level_label)

	var spacer_right := Control.new()
	spacer_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(spacer_right)

	_coins_button = _build_coins_button(root)


## Gems column with a flat Button in place of the value label (H9): tapping
## opens the Special screen. Diamond text distinguishes it from coins.
func _build_gems_button(parent: Node) -> Button:
	var column := VBoxContainer.new()
	column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(column)

	var caption := Label.new()
	caption.theme_type_variation = "LabelDim"
	caption.add_theme_font_size_override("font_size", CAPTION_FONT_SIZE)
	caption.text = tr("header_gems")
	column.add_child(caption)

	var button := Button.new()
	button.theme_type_variation = &"ButtonNav"
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_color_override("font_color", ThemeFactory.COLOR_DIAMOND)
	button.add_theme_color_override("font_hover_color", ThemeFactory.COLOR_DIAMOND)
	button.pressed.connect(_on_gems_pressed)
	column.add_child(button)
	return button


## Coins column with a flat Button in place of the value label (same caption
## layout as the gems button). ButtonNav variation: transparent at rest,
## gold flash on press.
func _build_coins_button(parent: Node) -> Button:
	var column := VBoxContainer.new()
	column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(column)

	var caption := Label.new()
	caption.theme_type_variation = "LabelDim"
	caption.add_theme_font_size_override("font_size", CAPTION_FONT_SIZE)
	caption.text = tr("header_coins")
	column.add_child(caption)

	var button := Button.new()
	button.theme_type_variation = &"ButtonNav"
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_color_override("font_color", ThemeFactory.COLOR_GOLD)
	button.add_theme_color_override("font_hover_color", ThemeFactory.COLOR_GOLD)
	button.pressed.connect(_on_coins_pressed)
	column.add_child(button)
	return button


# --- Data ---------------------------------------------------------------------

func _refresh_from_profile() -> void:
	var player_name: String = str(_profile.get("name", ""))
	var level: int = int(_profile.get("level", 1))
	_avatar_label.text = player_name.substr(0, 1).to_upper() if player_name != "" else "?"
	_name_label.text = player_name
	_level_label.text = tr("profile_level") % [level]
	_coins_button.text = str(int(_profile.get("coins", 0)))
	_gems_button.text = str(int(_profile.get("gems", 0)))


func _on_profile_updated(profile: Dictionary) -> void:
	_profile = profile
	_refresh_from_profile()


func _on_currency_changed(currency: String, amount: int) -> void:
	if currency == "coins":
		_coins_button.text = str(amount)
	elif currency == "gems":
		_gems_button.text = str(amount)


func _on_coins_pressed() -> void:
	EventBus.navigation_requested.emit(ScreenIds.SHOP)


func _on_gems_pressed() -> void:
	EventBus.navigation_requested.emit(ScreenIds.SPECIAL)


## H9: tapping the center avatar/name/level block opens the Profile screen.
func _on_profile_tapped(event: InputEvent) -> void:
	var is_press := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		is_press = true
	elif event is InputEventScreenTouch and event.pressed:
		is_press = true
	if not is_press:
		return
	get_viewport().set_input_as_handled()
	EventBus.navigation_requested.emit(ScreenIds.PROFILE)


func _on_locale_applied(_language_code: String) -> void:
	_refresh_from_profile()
