class_name DialogHost
extends Control
## Hosts at most one dialog at a time: dim backdrop + centered panel (jar art
## by default, flat style for content-heavy dialogs — see open()).
## Used for everything that "opens" on top of a screen without being a screen
## itself (legal pages, support, detail views). New requests while a dialog
## is open are rejected with a warning so callers keep valid references.

signal dialog_opened(dialog: PanelContainer)
signal dialog_closed(dialog: PanelContainer)

const BACKDROP_COLOR: Color = Color(0.0, 0.0, 0.0, 0.55)
## Text dialogs get a bounded size so the jar-shaped panel art stays near its
## native (near-square) aspect — the 9-slice middle stretches badly when the
## panel is much taller or wider than the artwork.
const TEXT_DIALOG_SIZE: Vector2 = Vector2(560, 640)

var _backdrop: ColorRect = null
var _center: CenterContainer = null
var _panel: PanelContainer = null
var _closable: bool = true


## Opens a dialog with custom content. Returns the panel (to reach into the
## caller's own content) or null when rejected. size_hint (non-zero) bounds the
## panel to that minimum; content may grow it, and the viewport caps it.
## use_art=false keeps the flat panel style — for tall content-heavy dialogs
## where the jar art's fixed-width glass walls would dominate the frame.
func open(content: Control, title: String = "", closable: bool = true, size_hint: Vector2 = Vector2.ZERO, use_art: bool = true) -> PanelContainer:
	if is_open():
		push_warning("DialogHost: a dialog is already open; new request ignored")
		return null
	if content == null:
		push_error("DialogHost.open() needs a content control")
		return null
	_closable = closable

	_backdrop = ColorRect.new()
	_backdrop.color = BACKDROP_COLOR
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_center)

	_panel = PanelContainer.new()
	if use_art:
		_panel.theme_type_variation = UISkins.DIALOG_PANEL
	if size_hint != Vector2.ZERO:
		var viewport := get_viewport().get_visible_rect().size
		_panel.custom_minimum_size = size_hint.clamp(
			Vector2(360, 320), Vector2(viewport.x * 0.94, viewport.y * 0.88)
		)
	_center.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	_panel.add_child(vbox)

	if title != "":
		vbox.add_child(_build_header(title, use_art))

	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(content)

	dialog_opened.emit(_panel)
	return _panel


## Convenience dialog: title + wrapped, scrollable body text.
func open_text(title: String, body: String) -> PanelContainer:
	var label := Label.new()
	# Ink: the jar art's body is cream (see LabelTitleInk).
	label.theme_type_variation = "LabelInk"
	label.text = body
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# EXPAND_FILL is mandatory: a ScrollContainer gives its child only the
	# minimum width otherwise, and an autowrapped Label's minimum is ~0 — the
	# body would wrap one character per line.
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.add_child(label)
	return open(scroll, title, true, TEXT_DIALOG_SIZE)


func close() -> void:
	if not is_open():
		return
	var panel := _panel
	_panel = null
	if _backdrop != null and is_instance_valid(_backdrop):
		_backdrop.queue_free()
	_backdrop = null
	# Free the whole subtree (the panel is a child of _center) — leaking _center
	# left an orphan full-rect container in the host on every close.
	if _center != null and is_instance_valid(_center):
		_center.queue_free()
	_center = null
	dialog_closed.emit(panel)


func is_open() -> bool:
	return _panel != null


func _build_header(title: String, use_art: bool) -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)

	var title_label := Label.new()
	# Ink on the jar's cream body; light on the flat dark panel.
	title_label.theme_type_variation = "LabelTitleInk" if use_art else "LabelTitle"
	title_label.text = title
	header.add_child(title_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	if _closable:
		var close_button := Button.new()
		close_button.text = tr("dialog_close")
		close_button.pressed.connect(close)
		header.add_child(close_button)
	return header


func _on_backdrop_input(event: InputEvent) -> void:
	if not _closable or not is_open():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_viewport().set_input_as_handled()
		close()
	elif event is InputEventScreenTouch and event.pressed:
		get_viewport().set_input_as_handled()
		close()
