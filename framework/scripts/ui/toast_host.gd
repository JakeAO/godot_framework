class_name ToastHost
extends Control
## Top-anchored toast queue. One toast visible at a time; new toasts queue
## behind it. Each toast slides in, lingers, then slides out. Tapping runs the
## optional tap_action (e.g. navigate to a feature) or quick-dismisses when no
## action is set. The gate callable blocks showing while app state is
## inopportune (fullscreen gameplay, dialog open); blocked toasts wait in the
## queue and are re-checked on state changes.

const SLIDE_SEC: float = 0.25
const DEFAULT_DURATION_SEC: float = 3.0
const REST_Y: float = 16.0

## Exposed so tests can shorten the linger time.
var toast_duration_sec: float = DEFAULT_DURATION_SEC

signal toast_shown(text: String)
signal toast_dismissed(text: String, tapped: bool)

var _queue: Array[Dictionary] = []
var _active: Dictionary = {}
var _gate: Callable = Callable()


## Sets the state filter. Receives the pending spec, returns whether it may
## show right now (blocked specs stay queued).
func set_gate(gate: Callable) -> void:
	_gate = gate


## Queues a toast. Spec keys: text, icon, tap_action (Callable),
## allowed_in_fullscreen (bool).
func push(spec: Dictionary) -> void:
	_queue.append(spec)
	_process_queue()


func clear() -> void:
	_kill_active(false)
	_queue.clear()


## Re-runs the queue check (called by UIManager on state changes).
func process_queue() -> void:
	_process_queue()


func queued_count() -> int:
	return _queue.size() + (1 if not _active.is_empty() else 0)


func _process_queue() -> void:
	if not _active.is_empty():
		return
	while not _queue.is_empty():
		var spec: Dictionary = _queue.pop_front()
		if _gate.is_valid() and not bool(_gate.call(spec)):
			# Inopportune state: hold the toast, re-check on the next change.
			_queue.push_front(spec)
			return
		_start_toast(spec)
		return


func _start_toast(spec: Dictionary) -> void:
	var root := PanelContainer.new()
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.gui_input.connect(_on_toast_input.bind(spec))

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	root.add_child(hbox)

	var icon_key := str(spec.get("icon", ""))
	if icon_key != "":
		var icon := ProtoIcon.new()
		icon.setup(icon_key, 20.0)
		hbox.add_child(icon)

	var label := Label.new()
	label.text = str(spec.get("text", ""))
	hbox.add_child(label)

	var min_size := root.get_combined_minimum_size()
	add_child(root)
	var vp := get_viewport().get_visible_rect().size
	var start_y := -min_size.y - 8.0
	root.position = Vector2(clampf((vp.x - min_size.x) * 0.5, 8.0, maxf(vp.x - min_size.x - 8.0, 8.0)), start_y)

	var tween := create_tween()
	tween.tween_property(root, "position:y", REST_Y, SLIDE_SEC)
	tween.tween_interval(toast_duration_sec)
	tween.tween_property(root, "position:y", start_y, SLIDE_SEC)
	tween.tween_callback(_on_toast_done.bind(spec))

	_active = {"root": root, "tween": tween, "spec": spec}
	toast_shown.emit(str(spec.get("text", "")))


func _on_toast_input(event: InputEvent, spec: Dictionary) -> void:
	var is_press := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		is_press = true
	elif event is InputEventScreenTouch and event.pressed:
		is_press = true
	if not is_press:
		return
	get_viewport().set_input_as_handled()
	var action: Callable = spec.get("tap_action", Callable())
	if action.is_valid():
		action.call()
	_kill_active(true)


func _on_toast_done(_spec: Dictionary) -> void:
	_kill_active(false)


func _kill_active(tapped: bool) -> void:
	if _active.is_empty():
		return
	var root: Control = _active["root"]
	var tween: Tween = _active["tween"]
	var text := str(_active.get("spec", {}).get("text", ""))
	_active = {}
	if is_instance_valid(tween):
		tween.kill()
	root.queue_free()
	toast_dismissed.emit(text, tapped)
	_process_queue()
