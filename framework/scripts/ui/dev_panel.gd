class_name DevPanel
extends Control
## Debug/QA overlay panel content — the UI half of the DevTools service
## (TDD §3.15). A GENERIC renderer: _ready() builds a fixed shell (backdrop,
## header, inline confirm bar, scroll host) and nothing else; setup()/refresh()
## render whatever control registry DevTools.get_sections() provides. The panel
## is built once and kept alive hidden by DevTools — refresh() re-reads values
## in place unless the structure key changed (full rebuild). Live updates are
## signal-driven (banner state, config reload) — no _process anywhere.
## ENGLISH-ONLY strings by design (dev tool, not user-facing content — no tr()).

signal closed_requested

const PANEL_WIDTH: int = 640
const PANEL_HEIGHT: int = 1080
const ROW_LABEL_WIDTH: float = 150.0

var _content: VBoxContainer = null
var _sections_box: VBoxContainer = null
var _confirm_bar: HBoxContainer = null
var _confirm_label: Label = null
var _structure_key: String = ""
## Widgets kept for in-place value refresh (rebuilt together with the tree).
var _value_rows: Array[Dictionary] = []   # {type, edit: LineEdit, get, set}
var _bools: Array[Dictionary] = []        # {check: CheckBox, get}
var _enums: Array[Dictionary] = []        # {picker: OptionButton, options, get}
var _live_labels: Array[Dictionary] = []  # {label: Label, get}
var _pending_confirm: Callable = Callable()


func _ready() -> void:
	_build_shell()
	AdManager.banner_state_changed.connect(_on_banner_state_changed)
	EventBus.config_loaded.connect(_on_config_loaded)


func _exit_tree() -> void:
	if AdManager.banner_state_changed.is_connected(_on_banner_state_changed):
		AdManager.banner_state_changed.disconnect(_on_banner_state_changed)
	if EventBus.config_loaded.is_connected(_on_config_loaded):
		EventBus.config_loaded.disconnect(_on_config_loaded)


# --- Shell (built once, never rebuilt) ---------------------------------------------

func _build_shell() -> void:
	var backdrop := ColorRect.new()
	_pin_full_rect(backdrop)
	backdrop.color = ThemeFactory.COLOR_BG.darkened(0.4)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var center := CenterContainer.new()
	_pin_full_rect(center)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	center.add_child(box)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_FILL
	_content.add_theme_constant_override("separation", 16)
	scroll.add_child(_content)

	var header := HBoxContainer.new()
	_content.add_child(header)
	var title := Label.new()
	title.text = "DEV TOOLS"
	title.theme_type_variation = "LabelTitle"
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close := Button.new()
	close.text = "X"
	close.pressed.connect(func() -> void: closed_requested.emit())
	header.add_child(close)

	# Destructive actions confirm INLINE (UIManager's dialog host is on layer 10,
	# below this overlay — it would render behind the panel).
	_confirm_bar = HBoxContainer.new()
	_confirm_bar.visible = false
	_content.add_child(_confirm_bar)
	_confirm_label = Label.new()
	_confirm_label.theme_type_variation = "LabelGold"
	_confirm_bar.add_child(_confirm_label)
	var bar_spacer := Control.new()
	bar_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_bar.add_child(bar_spacer)
	var yes := Button.new()
	yes.text = "Yes"
	yes.theme_type_variation = "ButtonPrimary"
	yes.pressed.connect(_on_confirm_yes)
	_confirm_bar.add_child(yes)
	var no := Button.new()
	no.text = "No"
	no.pressed.connect(_hide_confirm_bar)
	_confirm_bar.add_child(no)

	_sections_box = VBoxContainer.new()
	_content.add_child(_sections_box)


# --- Registry rendering ---------------------------------------------------------------

## First open: render the registry. DevTools calls this once per panel instance.
func setup(sections: Array[Dictionary], structure_key: String) -> void:
	_rebuild(sections, structure_key)


## Later opens: in-place value refresh unless the config structure changed.
func refresh(sections: Array[Dictionary], structure_key: String) -> void:
	if structure_key != _structure_key:
		_rebuild(sections, structure_key)
	else:
		_refresh_values()


func _rebuild(sections: Array[Dictionary], structure_key: String) -> void:
	_structure_key = structure_key
	for child in _sections_box.get_children():
		_sections_box.remove_child(child)
		child.queue_free()
	_value_rows.clear()
	_bools.clear()
	_enums.clear()
	_live_labels.clear()
	_pending_confirm = Callable()
	_hide_confirm_bar()
	for section in sections:
		var title := Label.new()
		title.text = str(section.get("title", ""))
		title.theme_type_variation = "LabelGold"
		_sections_box.add_child(title)
		var controls: Array = section.get("controls", [])
		for spec in controls:
			if typeof(spec) == TYPE_DICTIONARY:
				_add_control(_sections_box, spec as Dictionary)
	_refresh_values()


func _add_control(box: VBoxContainer, spec: Dictionary) -> void:
	var label_text := str(spec.get("label", ""))
	var type_name := str(spec.get("type", ""))
	if type_name == DevTools.CTRL_ACTION:
		var press: Callable = spec.get("press", Callable())
		var btn := Button.new()
		btn.text = label_text
		btn.pressed.connect(func() -> void: press.call())
		box.add_child(btn)
	elif type_name == DevTools.CTRL_CONFIRM:
		var text := str(spec.get("text", ""))
		var press: Callable = spec.get("press", Callable())
		var btn := Button.new()
		btn.text = label_text
		btn.pressed.connect(func() -> void: _show_confirm_bar(text, press))
		box.add_child(btn)
	elif type_name == DevTools.CTRL_BOOL:
		var getter: Callable = spec.get("get", Callable())
		var setter: Callable = spec.get("set", Callable())
		var check := CheckBox.new()
		check.text = label_text
		check.button_pressed = bool(getter.call())
		check.toggled.connect(func(on: bool) -> void: setter.call(on))
		box.add_child(check)
		_bools.append({"check": check, "get": getter})
	elif type_name == DevTools.CTRL_ENUM:
		var row := HBoxContainer.new()
		box.add_child(row)
		row.add_child(_row_label(label_text))
		var picker := OptionButton.new()
		picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var options: Array = spec.get("options", [])
		for option in options:
			picker.add_item(str(option))  # auto ids run 0..n-1, so id == index
		row.add_child(picker)
		var getter: Callable = spec.get("get", Callable())
		var setter: Callable = spec.get("set", Callable())
		picker.item_selected.connect(func(index: int) -> void: setter.call(str(picker.get_item_text(index))))
		_enums.append({"picker": picker, "options": options, "get": getter})
	elif type_name == DevTools.CTRL_LABEL:
		var row := HBoxContainer.new()
		box.add_child(row)
		var name_label := Label.new()
		name_label.text = label_text + ":"
		name_label.custom_minimum_size.x = ROW_LABEL_WIDTH
		row.add_child(name_label)
		var value_label := Label.new()
		value_label.theme_type_variation = "LabelDim"
		value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(value_label)
		var getter: Callable = spec.get("get", Callable())
		_live_labels.append({"label": value_label, "get": getter})
	else:  # int / float / string — value row with validation + echo
		_add_value_row(box, label_text, type_name, spec)


func _add_value_row(box: VBoxContainer, label_text: String, type_name: String, spec: Dictionary) -> void:
	var row := HBoxContainer.new()
	box.add_child(row)
	row.add_child(_row_label(label_text))
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.placeholder_text = "value"
	row.add_child(edit)
	var set_btn := Button.new()
	set_btn.text = "Set"
	row.add_child(set_btn)
	var getter: Callable = spec.get("get", Callable())
	var setter: Callable = spec.get("set", Callable())
	edit.text_submitted.connect(func(_text: String) -> void: _apply_value_edit(type_name, edit, getter, setter))
	set_btn.pressed.connect(func() -> void: _apply_value_edit(type_name, edit, getter, setter))
	_value_rows.append({"type": type_name, "edit": edit, "get": getter, "set": setter})


## Parses + validates the field (invalid input warns and writes nothing),
## applies via the spec's setter, then echoes the canonical stored value back.
func _apply_value_edit(type_name: String, edit: LineEdit, getter: Callable, setter: Callable) -> void:
	var text := edit.text.strip_edges()
	var value: Variant
	if type_name == DevTools.CTRL_INT:
		if not text.is_valid_int():
			push_warning("DevPanel: '%s' is not a valid integer" % text)
			return
		value = int(text)
	elif type_name == DevTools.CTRL_FLOAT:
		if not text.is_valid_float():
			push_warning("DevPanel: '%s' is not a valid float" % text)
			return
		value = float(text)
	else:  # string
		value = text
	setter.call(value)
	edit.text = _format_value(type_name, getter.call())


func _format_value(type_name: String, value: Variant) -> String:
	if type_name == DevTools.CTRL_INT:
		return str(int(value))
	if type_name == DevTools.CTRL_FLOAT:
		var f := float(value)
		if is_equal_approx(f, roundf(f)):
			return str(int(f))
		return str(f)
	return str(value)


# --- In-place value refresh (no rebuild, no allocation churn) -------------------------

## Re-reads every getter and updates the widgets in place.
func _refresh_values() -> void:
	for entry in _value_rows:
		var edit := entry["edit"] as LineEdit
		edit.text = _format_value(str(entry["type"]), (entry["get"] as Callable).call())
	for entry in _bools:
		var check := entry["check"] as CheckBox
		check.set_pressed_no_signal(bool((entry["get"] as Callable).call()))
	for entry in _enums:
		var picker := entry["picker"] as OptionButton
		var options: Array = entry["options"]
		picker.select(options.find(str((entry["get"] as Callable).call())))
	for entry in _live_labels:
		var label := entry["label"] as Label
		label.text = str((entry["get"] as Callable).call())


# --- Live refresh (signal-driven, never polled) ----------------------------------------

func _on_banner_state_changed(_state: String, _creative: Dictionary) -> void:
	_on_live_update()


func _on_config_loaded() -> void:
	_on_live_update()


## Value-only changes never rebuild the tree; a refetch that changes the flag/
## experiment SET is handled by DevTools on the next open (structure key).
func _on_live_update() -> void:
	if not is_visible():
		return
	_refresh_values()


# --- Confirm bar -----------------------------------------------------------------------

func _show_confirm_bar(text: String, press: Callable) -> void:
	_pending_confirm = press
	_confirm_label.text = text
	_confirm_bar.visible = true


func _hide_confirm_bar() -> void:
	_confirm_bar.visible = false


func _on_confirm_yes() -> void:
	var press := _pending_confirm
	_pending_confirm = Callable()
	if press.is_valid():
		press.call()
	_hide_confirm_bar()


# --- Helpers ------------------------------------------------------------------------------

func _row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = ROW_LABEL_WIDTH
	return label


## Explicit anchor/offset writes (NOT set_anchors_preset — that locks 0x0
## after tree entry on Godot 4.7; see NOTES.md).
func _pin_full_rect(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0
