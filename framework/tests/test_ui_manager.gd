extends GutTest
## UIManager overlay services: dialogs (open/reject/close), tooltips (show +
## dismiss on any other interaction), toasts (queueing, tap action, state
## filtering via fullscreen/dialog gate) and the tutorial/FTUE host
## (input swallow + interact-to-advance).

var _host: Control
var _original_toast_duration: float = ToastHost.DEFAULT_DURATION_SEC


func before_all() -> void:
	# test_screen_manager.gd (runs earlier, same process) freed its host and
	# with it the shell + every cached screen; reset that stale state so a
	# fresh attach() works.
	if not is_instance_valid(ScreenManager._shell):
		ScreenManager._shell = null
	ScreenManager._screens.clear()
	_host = Control.new()
	add_child(_host)
	ScreenManager.attach(_host)
	_original_toast_duration = UIManager.toast_host.toast_duration_sec
	UIManager.toast_host.toast_duration_sec = 0.4
	# Neutralize the real gate (dialog/tutorial) so long-press behavior tests
	# are deterministic regardless of FTUE state; the gate tests restore it.
	UIManager.tooltip_host.set_gate(_tooltip_gate_allow_all)


func after_all() -> void:
	UIManager.tooltip_host.set_gate(UIManager._can_trigger_tooltip)
	UIManager.toast_host.toast_duration_sec = _original_toast_duration
	if is_instance_valid(_host):
		_host.queue_free()


# --- Dialogs --------------------------------------------------------------------

func test_text_dialog_opens_with_title_and_body() -> void:
	watch_signals(UIManager.dialog_host)
	var panel: PanelContainer = UIManager.show_text_dialog("My Title", "Some body text")
	assert_not_null(panel, "show_text_dialog returns the panel")
	assert_true(UIManager.is_dialog_open(), "dialog reported open")
	assert_signal_emitted(UIManager.dialog_host, "dialog_opened", "opened signal emitted")


func test_second_dialog_rejected_with_warning() -> void:
	UIManager.show_text_dialog("First", "one")
	var second: PanelContainer = UIManager.show_text_dialog("Second", "two")
	assert_null(second, "second dialog rejected while one is open")
	assert_push_warning("already open", "rejection warns the caller")
	assert_true(UIManager.is_dialog_open(), "original dialog still open")


func test_close_dialog_emits_closed() -> void:
	UIManager.show_text_dialog("T", "B")
	watch_signals(UIManager.dialog_host)
	UIManager.close_current_dialog()
	assert_false(UIManager.is_dialog_open(), "dialog closed")
	assert_signal_emitted(UIManager.dialog_host, "dialog_closed", "closed signal emitted")


# --- Tooltips -------------------------------------------------------------------

func test_tooltip_shows_above_anchor_and_dismisses_on_other_input() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)

	UIManager.show_tooltip(anchor, "Hint text", "info")
	await wait_seconds(0.15)
	assert_true(UIManager.tooltip_host.has_tooltip(), "tooltip visible after show")
	var tip := UIManager.tooltip_host._tooltip
	assert_lt(tip.position.y, anchor.get_global_rect().position.y, "tooltip positioned above the anchor")

	UIManager.tooltip_host._input(_make_click(Vector2(10.0, 10.0)))
	await wait_seconds(0.15)
	assert_false(UIManager.tooltip_host.has_tooltip(), "any other interaction dismisses the tooltip")
	anchor.queue_free()


func test_long_press_shows_tooltip_after_hold() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)
	UIManager.attach_tooltip(anchor, "Hold hint", "info")

	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	assert_false(UIManager.tooltip_host.has_tooltip(), "no tooltip before the hold duration elapses")
	await wait_seconds(0.65)
	assert_true(UIManager.tooltip_host.has_tooltip(), "tooltip shown after holding LONG_PRESS_SEC")
	assert_eq(_tooltip_text(), "Hold hint", "attached text is shown")

	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	await get_tree().process_frame
	assert_true(UIManager.tooltip_host.has_tooltip(), "releasing the long-press does not dismiss its own tooltip")
	UIManager.dismiss_tooltip()
	await get_tree().process_frame
	anchor.queue_free()


func test_release_before_hold_duration_cancels() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)
	UIManager.attach_tooltip(anchor, "Hold hint")

	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.2)
	assert_false(UIManager.tooltip_host.has_tooltip(), "still holding: no tooltip yet")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	await wait_seconds(0.6)
	assert_false(UIManager.tooltip_host.has_tooltip(), "early release cancels the candidate")
	anchor.queue_free()


func test_move_beyond_slop_cancels_candidate() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)
	UIManager.attach_tooltip(anchor, "Hold hint")

	var center := _center_of(anchor)
	UIManager.tooltip_host._input(_make_touch_press(center))
	UIManager.tooltip_host._input(_make_drag(center + Vector2(40.0, 0.0)))
	await wait_seconds(0.65)
	assert_false(UIManager.tooltip_host.has_tooltip(), "drag beyond the slop cancels the candidate")
	UIManager.tooltip_host._input(_make_touch_release(center + Vector2(40.0, 0.0)))
	anchor.queue_free()


func test_long_press_on_unattached_control_does_nothing() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)

	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.65)
	assert_false(UIManager.tooltip_host.has_tooltip(), "only attached controls trigger tooltips")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	anchor.queue_free()


func test_reattach_refreshes_text_and_detach_stops_triggering() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)

	UIManager.attach_tooltip(anchor, "first")
	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.65)
	assert_eq(_tooltip_text(), "first", "initial attach text shown")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	UIManager.dismiss_tooltip()
	await get_tree().process_frame

	UIManager.attach_tooltip(anchor, "second")
	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.65)
	assert_eq(_tooltip_text(), "second", "re-attach refreshes the text (locale change path)")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	UIManager.dismiss_tooltip()
	await get_tree().process_frame

	UIManager.detach_tooltip(anchor)
	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.65)
	assert_false(UIManager.tooltip_host.has_tooltip(), "detached control no longer triggers")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	anchor.queue_free()


func test_dialog_open_dismisses_current_and_blocks_new_tooltips() -> void:
	UIManager.tooltip_host.set_gate(UIManager._can_trigger_tooltip)
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)
	UIManager.attach_tooltip(anchor, "Hold hint")

	UIManager.show_tooltip(anchor, "current")
	await wait_seconds(0.1)
	assert_true(UIManager.tooltip_host.has_tooltip(), "tooltip visible before the dialog opens")

	UIManager.show_text_dialog("T", "B")
	await get_tree().process_frame
	assert_false(UIManager.tooltip_host.has_tooltip(), "dialog open dismisses the current tooltip")

	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.65)
	assert_false(UIManager.tooltip_host.has_tooltip(), "gate blocks new tooltips while a dialog is open")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	UIManager.close_current_dialog()
	await get_tree().process_frame
	anchor.queue_free()


func test_tutorial_active_blocks_new_tooltips() -> void:
	UIManager.tooltip_host.set_gate(UIManager._can_trigger_tooltip)
	var anchor := Button.new()
	anchor.position = Vector2(300.0, 400.0)
	anchor.size = Vector2(120.0, 60.0)
	_host.add_child(anchor)
	UIManager.attach_tooltip(anchor, "Hold hint")

	var target := Button.new()
	target.position = Vector2(50.0, 50.0)
	target.size = Vector2(80.0, 40.0)
	_host.add_child(target)
	UIManager.show_tutorial_step(target, "hold on")
	await wait_seconds(0.1)
	assert_true(UIManager.tutorial_host.is_active(), "tutorial active for the gate check")

	UIManager.tooltip_host._input(_make_touch_press(_center_of(anchor)))
	await wait_seconds(0.65)
	assert_false(UIManager.tooltip_host.has_tooltip(), "gate blocks new tooltips while a tutorial is active")
	UIManager.tooltip_host._input(_make_touch_release(_center_of(anchor)))
	UIManager.cancel_tutorial()
	await get_tree().process_frame
	anchor.queue_free()
	target.queue_free()


# --- Toasts ---------------------------------------------------------------------

func test_toast_shows_and_auto_dismisses() -> void:
	watch_signals(UIManager.toast_host)
	UIManager.push_toast("hello toast", "check")
	await wait_seconds(0.5)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_shown", ["hello toast"])
	await wait_seconds(1.2)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_dismissed", ["hello toast", false])


func test_toast_queue_shows_in_order() -> void:
	watch_signals(UIManager.toast_host)
	UIManager.push_toast("first")
	UIManager.push_toast("second")
	await wait_seconds(0.5)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_shown", ["first"])
	assert_false(UIManager.toast_host._active.is_empty(), "only one toast active at a time")
	await wait_seconds(1.2)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_shown", ["second"])


func test_toast_tap_runs_action_and_dismisses() -> void:
	watch_signals(UIManager.toast_host)
	# Lambdas capture locals by value; a Dictionary gives the lambda a shared
	# reference it can mutate.
	var state: Dictionary = {"tapped": false}
	UIManager.push_toast("tap me", "", func() -> void: state["tapped"] = true)
	await wait_seconds(0.5)
	assert_true(UIManager.toast_host._active.has("spec"), "toast is active")
	var spec: Dictionary = UIManager.toast_host._active["spec"]
	UIManager.toast_host._on_toast_input(_make_click(Vector2.ZERO), spec)
	assert_true(bool(state["tapped"]), "tap action ran")
	await wait_seconds(0.1)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_dismissed", ["tap me", true])


func test_toast_held_while_fullscreen_then_shows() -> void:
	watch_signals(UIManager.toast_host)
	EventBus.navigation_requested.emit(ScreenIds.GAME)
	await wait_seconds(0.1)
	UIManager.push_toast("nope in game")
	await wait_seconds(0.5)
	assert_eq(UIManager.toast_host.queued_count(), 1, "toast held while gameplay is fullscreen")

	EventBus.navigation_requested.emit(ScreenIds.HOME)
	await wait_seconds(0.6)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_shown", ["nope in game"])


func test_toast_allowed_in_fullscreen_shows_immediately() -> void:
	watch_signals(UIManager.toast_host)
	EventBus.navigation_requested.emit(ScreenIds.GAME)
	await wait_seconds(0.1)
	UIManager.push_toast("urgent", "", Callable(), true)
	await wait_seconds(0.5)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_shown", ["urgent"])
	EventBus.navigation_requested.emit(ScreenIds.HOME)
	await wait_seconds(0.1)


func test_toast_held_while_dialog_open_then_shows() -> void:
	watch_signals(UIManager.toast_host)
	UIManager.show_text_dialog("T", "B")
	UIManager.push_toast("wait for dialog")
	await wait_seconds(0.5)
	assert_eq(UIManager.toast_host.queued_count(), 1, "toast held while a dialog is open")
	UIManager.close_current_dialog()
	await wait_seconds(0.6)
	assert_signal_emitted_with_parameters(UIManager.toast_host, "toast_shown", ["wait for dialog"])


# --- Tutorial / FTUE ----------------------------------------------------------------

func test_tutorial_swallows_outside_input_and_finishes_on_target_interact() -> void:
	var target := Button.new()
	target.position = Vector2(300.0, 400.0)
	target.size = Vector2(120.0, 60.0)
	_host.add_child(target)

	watch_signals(target)
	watch_signals(UIManager.tutorial_host)
	UIManager.show_tutorial_step(target, "Tap the button")
	await wait_seconds(0.1)
	assert_true(UIManager.tutorial_host.is_active(), "tutorial active")

	# Full press+release clicks (a real tap always releases; the host dedupes
	# a second synthetic press of one physical tap until the release arrives).
	var outside := target.get_global_rect().end + Vector2(80.0, 80.0)
	UIManager.tutorial_host._on_overlay_input(_make_click(outside))
	UIManager.tutorial_host._on_overlay_input(_make_release(outside))
	assert_signal_not_emitted(target, "pressed", "input outside the highlighted element is swallowed")

	var center := target.get_global_rect().position + target.get_global_rect().size * 0.5
	UIManager.tutorial_host._on_overlay_input(_make_click(center))
	UIManager.tutorial_host._on_overlay_input(_make_release(center))
	assert_signal_emitted(target, "pressed", "interaction on the target is forwarded to it")
	assert_signal_emitted(UIManager.tutorial_host, "tutorial_finished", "single-step tutorial finishes")
	target.queue_free()


func test_tutorial_multi_step_advances_in_order() -> void:
	var first := Button.new()
	first.position = Vector2(100.0, 300.0)
	first.size = Vector2(80.0, 50.0)
	_host.add_child(first)
	var second := Button.new()
	second.position = Vector2(400.0, 300.0)
	second.size = Vector2(80.0, 50.0)
	_host.add_child(second)

	watch_signals(UIManager.tutorial_host)
	UIManager.run_tutorial([
		{"target": first, "text": "step one"},
		{"target": second, "text": "step two"},
	])
	await wait_seconds(0.1)

	var center_one := first.get_global_rect().position + first.get_global_rect().size * 0.5
	UIManager.tutorial_host._on_overlay_input(_make_click(center_one))
	UIManager.tutorial_host._on_overlay_input(_make_release(center_one))
	assert_signal_emitted_with_parameters(UIManager.tutorial_host, "tutorial_step_completed", [0])
	assert_true(UIManager.tutorial_host.is_active(), "second step is active after the first interaction")

	var center_two := second.get_global_rect().position + second.get_global_rect().size * 0.5
	UIManager.tutorial_host._on_overlay_input(_make_click(center_two))
	UIManager.tutorial_host._on_overlay_input(_make_release(center_two))
	assert_signal_emitted(UIManager.tutorial_host, "tutorial_finished", "sequence finishes on the last step")
	first.queue_free()
	second.queue_free()


# --- Helpers --------------------------------------------------------------------

func _make_click(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = true
	return event


func _make_release(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = false
	return event


func _make_touch_press(pos: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.position = pos
	event.pressed = true
	return event


func _make_touch_release(pos: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.position = pos
	event.pressed = false
	return event


func _make_drag(pos: Vector2) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.position = pos
	return event


func _center_of(control: Control) -> Vector2:
	var rect := control.get_global_rect()
	return rect.position + rect.size * 0.5


func _tooltip_text() -> String:
	var tip := UIManager.tooltip_host._tooltip
	if tip == null:
		return ""
	for child in (tip.get_child(0) as Control).get_children():
		if child is Label:
			return (child as Label).text
	return ""


func _tooltip_gate_allow_all() -> bool:
	return true
