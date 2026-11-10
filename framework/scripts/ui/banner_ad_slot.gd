class_name BannerAdSlot
extends Control
## Fixed slot at the bottom of every screen that renders the mock banner ad.
##
## Subscribes to AdManager.banner_state_changed (the manager's own signal,
## allowed for direct UI consumption per AGENTS.md). Non-loaded states render
## as an empty panel so the layout never jumps; a loaded creative is painted
## with its own color and contrast-checked text (data-driven styling, not
## hardcoded UI chrome).

var _panel: Panel
var _title_label: Label
var _body_label: Label


func _ready() -> void:
	_build_layout()
	AdManager.banner_state_changed.connect(_on_banner_state_changed)
	_sync_with_manager()


func _exit_tree() -> void:
	if AdManager.banner_state_changed.is_connected(_on_banner_state_changed):
		AdManager.banner_state_changed.disconnect(_on_banner_state_changed)


# --- Layout -------------------------------------------------------------------

func _build_layout() -> void:
	_panel = Panel.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	var content := VBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	for margin_key in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		content.add_theme_constant_override(margin_key, ThemeFactory.CONTENT_MARGIN)
	_panel.add_child(content)

	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_title_label)

	_body_label = Label.new()
	_body_label.theme_type_variation = "LabelDim"
	_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_body_label)


# --- State --------------------------------------------------------------------

func _sync_with_manager() -> void:
	if not AdManager.is_enabled():
		visible = false
		return
	visible = true
	var state := AdManager.get_state()
	if state == AdManager.STATE_LOADED:
		_render_creative(AdManager.get_current_creative())
	else:
		_clear_creative()


func _on_banner_state_changed(state: String, creative: Dictionary) -> void:
	if not AdManager.is_enabled():
		visible = false
		return
	visible = true
	if state == AdManager.STATE_LOADED:
		_render_creative(creative)
	else:
		_clear_creative()


func _render_creative(creative: Dictionary) -> void:
	if bool(creative.get("native", false)):
		# Live AdMob mode: the OS draws the banner over this slot, so keep the
		# space reserved but paint nothing of our own.
		_clear_creative()
		return
	var color := Color(str(creative.get("color_hex", "#4f8cff")))
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(0)
	box.set_content_margin_all(0.0)
	_panel.add_theme_stylebox_override("panel", box)

	var text_color := _contrast_text_for(color)
	_title_label.text = str(creative.get("title", ""))
	_body_label.text = str(creative.get("body", ""))
	_title_label.add_theme_color_override("font_color", text_color)
	_body_label.add_theme_color_override("font_color", text_color)


func _clear_creative() -> void:
	_panel.remove_theme_stylebox_override("panel")
	_title_label.text = ""
	_body_label.text = ""
	_title_label.remove_theme_color_override("font_color")
	_body_label.remove_theme_color_override("font_color")


## Picks ink or white text for maximum contrast on the creative's background.
func _contrast_text_for(background: Color) -> Color:
	var luminance := 0.299 * background.r + 0.587 * background.g + 0.114 * background.b
	if luminance > 0.6:
		return ThemeFactory.COLOR_INK
	return Color.WHITE
