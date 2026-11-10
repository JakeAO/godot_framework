class_name TooltipHost
extends Control
## Long-press tooltip framework (GDD §8): opt-in per control via attach()/
## detach(). Holding an attached control for LONG_PRESS_SEC while moving no
## more than SLOP_PX shows one small icon+text bubble above it. Releasing
## early = a normal tap; moving beyond the slop = a drag — neither shows a
## tooltip.
##
## The host NEVER swallows input: a long-pressed button still fires on
## release, and dismissal of an existing tooltip is deferred so the dismissing
## interaction still works. New triggers are blocked while the gate callable
## returns false (UIManager wires it: dialog open / tutorial active).
##
## Attached entries persist across tree exits — screens are cached and reused,
## so a tooltip keeps working after navigating away and back. Freed controls
## are dropped lazily (purged on attach, skipped at hit-test).

signal tooltip_dismissed

const LONG_PRESS_SEC: float = 0.5
const SLOP_PX: float = 12.0

var _attached: Array[Dictionary] = []
var _candidate: Dictionary = {}
var _tooltip: PanelContainer = null
var _gate: Callable = Callable()


func attach(control: Control, text: String, icon_key: String = "") -> void:
	if control == null:
		return
	var i := _attached.size() - 1
	while i >= 0:
		var value: Variant = _attached[i]["control"]
		if not is_instance_valid(value):
			_attached.remove_at(i)
		elif (value as Control) == control:
			_attached.remove_at(i)
		i -= 1
	_attached.append({"control": control, "text": text, "icon_key": icon_key})


func detach(control: Control) -> void:
	var i := _attached.size() - 1
	while i >= 0:
		var value: Variant = _attached[i]["control"]
		if is_instance_valid(value) and (value as Control) == control:
			_attached.remove_at(i)
		i -= 1
	if not _candidate.is_empty():
		var cand_value: Variant = _candidate.get("control")
		if is_instance_valid(cand_value) and (cand_value as Control) == control:
			_candidate = {}


func set_gate(callable: Callable) -> void:
	_gate = callable


## Programmatic show (kept for API parity); long-press is the player-facing
## trigger.
func show_for(anchor: Control, text: String, icon_key: String = "") -> void:
	if anchor == null or not anchor.is_inside_tree():
		push_warning("TooltipHost: anchor is not in the tree; cannot position tooltip")
		return
	dismiss()

	_tooltip = PanelContainer.new()
	_tooltip.theme_type_variation = &"PanelTooltip"
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	_tooltip.add_child(hbox)

	if icon_key != "":
		var icon := ProtoIcon.new()
		icon.setup(icon_key, 18.0)
		hbox.add_child(icon)

	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 120.0
	hbox.add_child(label)

	add_child(_tooltip)
	call_deferred("_position_above", anchor)


func dismiss() -> void:
	_candidate = {}
	if _tooltip == null:
		return
	var tip := _tooltip
	_tooltip = null
	tip.queue_free()
	tooltip_dismissed.emit()


func has_tooltip() -> bool:
	return _tooltip != null


func _gate_allows() -> bool:
	if _gate.is_null():
		return true
	return bool(_gate.call())


func _input(event: InputEvent) -> void:
	# Early phase: the host is MOUSE_FILTER_IGNORE, so this sees every event
	# before GUI processing — and never consumes one.
	var press_pos := Vector2.INF
	if event is InputEventScreenTouch and event.pressed:
		press_pos = event.position
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		press_pos = event.position
	if press_pos != Vector2.INF:
		_on_press(press_pos)
		return

	var released := false
	if event is InputEventScreenTouch and not event.pressed:
		released = true
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		released = true
	if released:
		_candidate = {}
		return

	var drag_pos := Vector2.INF
	if event is InputEventScreenDrag:
		drag_pos = event.position
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		drag_pos = event.position
	if drag_pos != Vector2.INF and not _candidate.is_empty():
		var start: Vector2 = _candidate["pos"]
		if drag_pos.distance_to(start) > SLOP_PX:
			_candidate = {}


func _on_press(pos: Vector2) -> void:
	if has_tooltip():
		# A tooltip is up: this press dismisses it (deferred, so the tapped
		# control still works) and does NOT start a new candidate.
		call_deferred("dismiss")
		return
	if not _candidate.is_empty():
		return  # first finger wins; extra presses while a candidate is live are ignored
	if not _gate_allows():
		return
	var i := _attached.size() - 1
	while i >= 0:
		var entry: Dictionary = _attached[i]
		var value: Variant = entry["control"]
		if is_instance_valid(value):
			var control: Control = value as Control
			if control.is_inside_tree() and control.get_global_rect().has_point(pos):
				_candidate = {
					"control": control,
					"text": str(entry["text"]),
					"icon_key": str(entry["icon_key"]),
					"start_ms": int(Time.get_ticks_msec()),
					"pos": pos,
				}
				return
		i -= 1


func _process(_delta: float) -> void:
	if _candidate.is_empty():
		return
	var value: Variant = _candidate["control"]
	if not is_instance_valid(value):
		_candidate = {}
		return
	var control: Control = value as Control
	if not control.is_inside_tree():
		_candidate = {}
		return
	var elapsed_ms := int(Time.get_ticks_msec()) - int(_candidate["start_ms"])
	if elapsed_ms >= int(LONG_PRESS_SEC * 1000.0):
		var entry: Dictionary = _candidate.duplicate()
		_candidate = {}
		show_for(control, str(entry["text"]), str(entry["icon_key"]))


func _position_above(anchor: Control) -> void:
	if _tooltip == null or not is_instance_valid(anchor):
		return
	var rect := anchor.get_global_rect()
	var tip_size := _tooltip.size
	if tip_size == Vector2.ZERO:
		tip_size = _tooltip.get_combined_minimum_size()
	var vp := get_viewport().get_visible_rect().size
	var pos := Vector2(
		clampf(rect.position.x + rect.size.x * 0.5 - tip_size.x * 0.5, 8.0, maxf(vp.x - tip_size.x - 8.0, 8.0)),
		rect.position.y - tip_size.y - 10.0
	)
	if pos.y < 8.0:
		pos.y = rect.end.y + 10.0  # no room above -> flip below
	_tooltip.position = pos
