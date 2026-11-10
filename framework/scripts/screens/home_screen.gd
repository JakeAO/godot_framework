class_name HomeScreen
extends BaseScreen
## Home screen ("Adventure Ladder"). Renders the data-driven stage ladder
## (StageCatalog): stages below the current one are cleared, the current
## stage gets a gold PLAY button, and later stages are locked. Stage progress
## lives in the save "profile" domain under the "stage" key (default 1).

const PROFILE_DOMAIN: String = "profile"
const STAGE_KEY: String = "stage"
const META_DOMAIN: String = "meta"
const FTUE_DONE_KEY: String = "ftue_done"
## Ladder column width; centered in the content zone so it stays clear of the
## Home side zones (events left, offers right)
const CONTENT_WIDTH: int = 440

var _title: Label = null
var _stage_labels: Array[Label] = []
var _stage_buttons: Array[Button] = []
var _stage_locked: Array[Label] = []
var _ftue_running: bool = false
var _ftue_play_button: Button = null


func _ready() -> void:
	super._ready()
	if not EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.connect(_on_profile_updated)
	_maybe_start_ftue()


func _exit_tree() -> void:
	# Leaving Home mid-FTUE auto-cancels the tutorial (its target leaves the
	# tree); mark it done so it never re-runs. The normal PLAY path already
	# marks completion in _on_ftue_play_interacted before navigation happens.
	if _ftue_running and not bool(SaveSystem.get_value(META_DOMAIN, FTUE_DONE_KEY, false)):
		_mark_ftue_done()
	_ftue_running = false
	if EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.disconnect(_on_profile_updated)
	super._exit_tree()


func _apply_locale() -> void:
	_title.text = tr("home_title")
	_refresh()


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

	# Center the ladder column on BOTH axes inside the content zone.
	# (CenterContainer is deterministic; HBox+spacers only guarantees the
	# main axis.)
	var center_box := CenterContainer.new()
	center_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_child(center_box)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size.x = CONTENT_WIDTH
	vbox.add_theme_constant_override("separation", 12)
	center_box.add_child(vbox)

	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	for i in StageCatalog.stage_count():
		vbox.add_child(_build_stage_row(i + 1))


func _build_stage_row(_stage: int) -> PanelContainer:
	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	panel.add_child(row)

	var label := Label.new()
	row.add_child(label)
	_stage_labels.append(label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var button := Button.new()
	button.pressed.connect(_on_play_pressed)
	row.add_child(button)
	_stage_buttons.append(button)

	var locked := Label.new()
	locked.theme_type_variation = &"LabelDim"
	locked.visible = false
	row.add_child(locked)
	_stage_locked.append(locked)

	return panel


# --- State --------------------------------------------------------------------

func _refresh() -> void:
	var current_stage := clampi(
		int(SaveSystem.get_value(PROFILE_DOMAIN, STAGE_KEY, 1)),
		1, maxi(StageCatalog.stage_count(), 1)
	)
	for i in StageCatalog.stage_count():
		var def: StageDefinition = StageCatalog.get_stage(i + 1)
		_stage_labels[i].text = _stage_label_text(def)
		if def.id == current_stage:
			_stage_buttons[i].text = tr("home_play")
			_stage_buttons[i].visible = true
			_stage_locked[i].visible = false
		elif def.id < current_stage:
			_stage_buttons[i].visible = false
			_stage_locked[i].visible = false
		else:
			_stage_buttons[i].visible = false
			_stage_locked[i].text = tr("home_locked")
			_stage_locked[i].visible = true


## Ladder label: the stage's tr() key when set, else "Stage <id>".
func _stage_label_text(def: StageDefinition) -> String:
	if def.name_key != "":
		return tr(def.name_key)
	return tr("home_stage") % [def.id]


func _on_play_pressed() -> void:
	EventBus.navigation_requested.emit(ScreenIds.GAME)


func _on_profile_updated(_profile: Dictionary) -> void:
	_refresh()


# --- FTUE (GDD §8) -------------------------------------------------------------

## First-launch tutorial, runs once: highlights the ladder title, then the
## PLAY button. Completing step 2 forwards the press (round starts); any other
## exit cancels the tutorial. Both paths persist meta.ftue_done.
func _maybe_start_ftue() -> void:
	if bool(SaveSystem.get_value(META_DOMAIN, FTUE_DONE_KEY, false)):
		return
	var play_button: Button = null
	for button in _stage_buttons:
		if button.visible:
			play_button = button
			break
	if play_button == null:
		return
	_ftue_play_button = play_button
	UIManager.run_tutorial([
		# GDD §8: step 1 advances on ANY tap (acknowledge), step 2 requires the PLAY press.
		{"target": _title, "text": tr("ftue_ladder"), "anywhere": true},
		{"target": play_button, "text": tr("ftue_play"), "on_interact": _on_ftue_play_interacted},
	])
	_ftue_running = true


func _on_ftue_play_interacted() -> void:
	_mark_ftue_done()
	# on_interact replaces the default forwarding, so forward the press ourselves.
	if _ftue_play_button != null and is_instance_valid(_ftue_play_button):
		_ftue_play_button.emit_signal("pressed")


func _mark_ftue_done() -> void:
	var meta: Dictionary = SaveSystem.get_domain(META_DOMAIN)
	meta[FTUE_DONE_KEY] = true
	SaveSystem.set_domain(META_DOMAIN, meta)
	SaveSystem.save_game()
