class_name ResultsScreen extends BaseScreen
## Fullscreen post-round screen. Shows score, best, new-best badge, coins and
## XP earned from the latest GameResult (delivered via
## EventBus.gameplay_finished), with Play Again and Home actions.

var _title_label: Label = null
var _new_best_label: Label = null
var _score_label: Label = null
var _best_label: Label = null
var _coins_label: Label = null
var _xp_label: Label = null
var _modifiers_box: HBoxContainer = null
var _play_again_button: Button = null
var _home_button: Button = null

var _last_result: Dictionary = {}


func _ready() -> void:
	super._ready()
	if not EventBus.gameplay_finished.is_connected(_on_gameplay_finished):
		EventBus.gameplay_finished.connect(_on_gameplay_finished)


func _exit_tree() -> void:
	if EventBus.gameplay_finished.is_connected(_on_gameplay_finished):
		EventBus.gameplay_finished.disconnect(_on_gameplay_finished)
	super._exit_tree()


func _apply_locale() -> void:
	if _title_label != null:
		_title_label.text = tr("results_title")
	if _new_best_label != null:
		_new_best_label.text = tr("results_new_best")
	if _play_again_button != null:
		_play_again_button.text = tr("results_play_again")
	if _home_button != null:
		_home_button.text = tr("results_home")
	_refresh_from_last_result()


# --- UI -----------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	# Pin to full rect: an unanchored container shrinks to minimum size at top-left.
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	margin.add_child(vbox)

	var top_spacer := Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(top_spacer)

	_title_label = Label.new()
	_title_label.theme_type_variation = &"LabelTitle"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title_label)

	_new_best_label = Label.new()
	_new_best_label.theme_type_variation = &"LabelGold"
	_new_best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_new_best_label.visible = false
	vbox.add_child(_new_best_label)

	_score_label = Label.new()
	_score_label.theme_type_variation = &"LabelDim"
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_score_label)

	_best_label = Label.new()
	_best_label.theme_type_variation = &"LabelDim"
	_best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_best_label)

	_coins_label = Label.new()
	_coins_label.theme_type_variation = &"LabelGold"
	_coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_coins_label)

	_xp_label = Label.new()
	_xp_label.theme_type_variation = &"LabelDim"
	_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_xp_label)

	# Applied campaign modifiers (GDD §6): a badge row under the XP label,
	# hidden when the round had no active modifier campaigns.
	_modifiers_box = HBoxContainer.new()
	_modifiers_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_modifiers_box.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	_modifiers_box.visible = false
	vbox.add_child(_modifiers_box)

	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(bottom_spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	vbox.add_child(actions)

	_play_again_button = Button.new()
	_play_again_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_play_again_button.pressed.connect(_on_play_again_pressed)
	actions.add_child(_play_again_button)

	_home_button = Button.new()
	_home_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_home_button.pressed.connect(_on_home_pressed)
	actions.add_child(_home_button)


# --- State --------------------------------------------------------------------

func _refresh_from_last_result() -> void:
	if _score_label == null or _best_label == null or _coins_label == null or _xp_label == null:
		return
	var score: int = int(_last_result.get("score", 0))
	var best: int = int(_last_result.get("best_score", 0))
	var coins: int = int(_last_result.get("coins_earned", 0))
	var xp: int = int(_last_result.get("xp_earned", 0))
	if _new_best_label != null:
		_new_best_label.visible = bool(_last_result.get("is_new_best", false))
	_score_label.text = "%s: %d" % [tr("results_score"), score]
	_best_label.text = "%s: %d" % [tr("results_best"), best]
	_coins_label.text = tr("results_coins_earned") % [coins]
	_xp_label.text = tr("results_xp_earned") % [xp]
	_refresh_modifiers()


func _refresh_modifiers() -> void:
	if _modifiers_box == null:
		return
	for child in _modifiers_box.get_children():
		_modifiers_box.remove_child(child)
		child.queue_free()
	var modifiers: Variant = _last_result.get("modifiers_applied", [])
	if typeof(modifiers) != TYPE_ARRAY:
		modifiers = []
	for m in (modifiers as Array):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var mod := m as Dictionary
		var mult := float(mod.get("multiplier", 1.0))
		var mult_text := str(int(mult)) if mult == floorf(mult) else str(mult)
		var badge := Label.new()
		badge.theme_type_variation = &"LabelGold"
		badge.text = tr("results_modifier") % [mult_text, str(mod.get("title", ""))]
		_modifiers_box.add_child(badge)
	_modifiers_box.visible = not (modifiers as Array).is_empty()


func _on_gameplay_finished(result: Dictionary) -> void:
	_last_result = result
	_refresh_from_last_result()


func _on_play_again_pressed() -> void:
	EventBus.navigation_requested.emit(ScreenIds.GAME)


func _on_home_pressed() -> void:
	EventBus.navigation_requested.emit(ScreenIds.HOME)
