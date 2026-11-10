class_name TutorialHost
extends Control
## FTUE / tutorial overlay. Dims the screen, highlights the target element
## with a gold ring and a pointing arrow plus a text bubble, and swallows all
## input until the player interacts with the highlighted element — that
## interaction is forwarded to the element (pressed/toggled) and advances to
## the next step. Multi-step sequences run in order; cancel() ends early.
##
## INPUT DELIVERY (Godot 4, verified by tools/probe_tutorial_input.gd): GUI
## events are delivered to the TOPMOST non-IGNORE Control under the pointer —
## here the full-rect STOP _HighlightLayer child — and a STOP control consumes
## unhandled events, so this host's own _gui_input() would NEVER fire. The
## layer therefore forwards every event it receives to _on_overlay_input().

signal tutorial_step_completed(step_index: int)
signal tutorial_finished

var _steps: Array[Dictionary] = []
var _index: int = -1
var _overlay: _HighlightLayer = null
var _text_label: Label = null
## True while _interact() is running the step's on_interact/forwarding. A
## well-behaved on_interact may navigate away from the target's screen, which
## cancels this host via refresh_target() — an expected side effect, not the
## "target left the tree" anomaly that warning is for.
var _interacting: bool = false


## Runs a sequence of steps. Each step: {"target": Control, "text": String,
## "on_interact": Callable (optional — overrides the default forwarding)}.
func run_steps(steps: Array[Dictionary]) -> void:
	cancel()
	_steps = steps.duplicate()
	if _steps.is_empty():
		push_warning("TutorialHost.run_steps() called with no steps")
		return
	_index = 0
	_show_step()


func cancel() -> void:
	_hide_overlay()
	_steps.clear()
	_index = -1


## Called by UIManager on navigation: a step whose target left the tree (the
## screen it lived on was swapped out) cancels the tutorial.
func refresh_target() -> void:
	if _index < 0:
		return
	var target := _current_target()
	if target == null or not target.is_inside_tree():
		if not _interacting:
			push_warning("TutorialHost: tutorial target left the tree; cancelling")
		cancel()


func is_active() -> bool:
	return _index >= 0


func _process(_delta: float) -> void:
	if _index < 0 or _overlay == null:
		return
	var target := _current_target()
	if target == null or not target.is_inside_tree():
		push_warning("TutorialHost: tutorial target left the tree; cancelling")
		cancel()
		return
	_overlay.set_hole(target.get_global_rect())
	_position_text(target)


func _show_step() -> void:
	_hide_overlay()
	var step: Dictionary = _steps[_index]
	var target := _current_target()
	if target == null or not target.is_inside_tree():
		push_warning("TutorialHost: step %d has no valid target; skipping" % _index)
		_advance()
		return

	_overlay = _HighlightLayer.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	# The layer is where real GUI input lands (see class header); forward it.
	_overlay.input_received.connect(_on_overlay_input)
	_overlay.set_hole(target.get_global_rect())

	_text_label = Label.new()
	_text_label.text = str(step.get("text", ""))
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.custom_minimum_size.x = 260.0
	add_child(_text_label)
	_position_text(target)


func _position_text(target: Control) -> void:
	var rect := target.get_global_rect()
	var vp := get_viewport().get_visible_rect().size
	var label_size := _text_label.get_combined_minimum_size()
	var x := clampf(rect.position.x, 8.0, maxf(vp.x - label_size.x - 8.0, 8.0))
	var below_y := rect.end.y + 24.0
	if below_y + label_size.y <= vp.y - 8.0:
		_text_label.position = Vector2(x, below_y)
		_overlay.set_arrow(Vector2(rect.position.x + rect.size.x * 0.5, rect.end.y), 1.0)
	else:
		var above_y := maxf(rect.position.y - 24.0 - label_size.y, 8.0)
		_text_label.position = Vector2(x, above_y)
		_overlay.set_arrow(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y), -1.0)


## Receives every GUI event the highlight layer sees (it is the topmost
## non-IGNORE control under the pointer — see class header). Step shape:
## {"target": Control, "text": String, "on_interact": Callable?,
##  "anywhere": bool?} — with "anywhere", ANY tap completes the step (an
## off-target tap acknowledges without forwarding to the element).
func _on_overlay_input(event: InputEvent) -> void:
	if _index < 0 or _overlay == null:
		return
	var step: Dictionary = _steps[_index]
	var target := _current_target()
	if target == null:
		return

	var is_press := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		is_press = event.pressed
	elif event is InputEventScreenTouch:
		is_press = event.pressed
	else:
		return

	# One physical tap on a touch device ALSO produces an emulated mouse
	# event (and vice versa when emulate_touch_from_mouse is on). Emulated
	# events carry device == DEVICE_ID_EMULATION (-1); real touches are 0 and
	# real mice 32+. Swallow the emulated twin so a tap drives the step
	# exactly once. This is stateless on purpose: an earlier sticky
	# "press handled" flag cleared only on release stuck true forever when a
	# mid-step overlay swap lost the release event (gui.mouse_focus is
	# cleared when the focused control exits the tree), freezing the tutorial.
	if event.device == InputEvent.DEVICE_ID_EMULATION:
		get_viewport().set_input_as_handled()
		return

	if not is_press:
		get_viewport().set_input_as_handled()
		return

	var pressed_in_target := target.get_global_rect().has_point(event.position)
	var anywhere := bool(step.get("anywhere", false))
	if not pressed_in_target and not anywhere:
		# Everything else is swallowed while the tutorial is active.
		get_viewport().set_input_as_handled()
		return

	get_viewport().set_input_as_handled()
	_interact(step, target, pressed_in_target)


func _interact(step: Dictionary, target: Control, forward: bool = true) -> void:
	var completed_index := _index
	_interacting = true
	var on_interact: Callable = step.get("on_interact", Callable())
	if on_interact.is_valid():
		on_interact.call()
	elif forward and target is Button:
		target.emit_signal("pressed")
	elif forward and target is CheckBox:
		target.button_pressed = not target.button_pressed
		target.emit_signal("toggled", target.button_pressed)
	_interacting = false

	# on_interact may have ended the tutorial as a side effect — e.g. it
	# navigated away from the screen hosting the target, which cancels this
	# host via refresh_target(). Then _index changed and steps were cleared;
	# emit/advance again would report a bogus step index.
	if _index != completed_index:
		return
	tutorial_step_completed.emit(completed_index)
	_advance()


func _advance() -> void:
	_index += 1
	if _index < _steps.size():
		_show_step()
	else:
		cancel()
		tutorial_finished.emit()


func _hide_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	if _text_label != null and is_instance_valid(_text_label):
		_text_label.queue_free()
	_text_label = null


## The current step's target, or null when it is gone (never set or freed).
## A freed instance cannot be assigned to a typed variable without an engine
## error, so this goes through Variant + is_instance_valid().
func _current_target() -> Control:
	if _index < 0 or _index >= _steps.size():
		return null
	var value: Variant = _steps[_index].get("target", null)
	if not is_instance_valid(value):
		return null
	if value is Control:
		return value as Control
	return null


## Dim layer with a highlight "hole" around the target plus the pointing arrow.
class _HighlightLayer extends Control:
	const HOLE_PADDING: float = 6.0
	const DIM_COLOR: Color = Color(0.0, 0.0, 0.0, 0.6)
	const BORDER_COLOR: Color = ThemeFactory.COLOR_GOLD

	## Every GUI event this layer receives. It is the topmost non-IGNORE
	## control under the pointer and STOP-consumes events, so the host's own
	## _gui_input never sees them — the host connects to this signal instead.
	signal input_received(event: InputEvent)

	var hole_rect := Rect2()
	var arrow_tip := Vector2.ZERO
	var arrow_dir := 1.0


	func _gui_input(event: InputEvent) -> void:
		input_received.emit(event)


	func set_hole(rect: Rect2) -> void:
		hole_rect = rect.grow(HOLE_PADDING)
		queue_redraw()


	func set_arrow(tip: Vector2, dir: float) -> void:
		arrow_tip = tip
		arrow_dir = dir
		queue_redraw()


	func _draw() -> void:
		var vp := get_viewport().get_visible_rect().size
		var h := hole_rect

		if h.position.y > 0.0:
			draw_rect(Rect2(0.0, 0.0, vp.x, h.position.y), DIM_COLOR)
		if h.end.y < vp.y:
			draw_rect(Rect2(0.0, h.end.y, vp.x, vp.y - h.end.y), DIM_COLOR)
		if h.position.x > 0.0:
			draw_rect(Rect2(0.0, h.position.y, h.position.x, h.size.y), DIM_COLOR)
		if h.end.x < vp.x:
			draw_rect(Rect2(h.end.x, h.position.y, vp.x - h.end.x, h.size.y), DIM_COLOR)

		draw_rect(h, BORDER_COLOR, false, 3.0)

		# Arrow: tip touches the target edge, base extends toward the text.
		var spread := Vector2(10.0, 18.0 * arrow_dir)
		draw_colored_polygon(
			PackedVector2Array([arrow_tip, arrow_tip + Vector2(-spread.x, spread.y), arrow_tip + Vector2(spread.x, spread.y)]),
			BORDER_COLOR
		)
