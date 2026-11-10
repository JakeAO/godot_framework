extends SceneTree
## FTUE input probe: boots the REAL main scene headless with a FRESH temp save,
## waits for the first-launch tutorial overlay, then pushes REAL viewport input
## (mouse clicks) and reports whether the tutorial advances. This exercises the
## actual GUI hit-testing pipeline (unlike unit tests that call handlers
## directly), so it catches "input never reaches the handler" regressions.
## Run: ~/tools/godot --headless --path . -s res://tools/probe_tutorial_input.gd

const SETTLE_FRAMES: int = 40


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	var save_system: Node = root.get_node("SaveSystem")
	var tmp := "user://gut_tmp/probe_ftue_save_%d.json" % Time.get_ticks_usec()
	save_system.set_save_path(tmp)

	var packed: PackedScene = load("res://scenes/main.tscn")
	var main := packed.instantiate()
	root.add_child(main)
	for i in SETTLE_FRAMES:
		await process_frame

	var ui_manager: Node = root.get_node("UIManager")
	var host: Control = ui_manager.tutorial_host
	print("tutorial active before click: ", host.is_active())
	if not host.is_active():
		print("PROBE FAIL: FTUE did not start (unexpected save state)")
		quit(1)
		return

	var screen_manager: Node = root.get_node("ScreenManager")
	var shell: Control = screen_manager._shell
	var home: Control = shell.content_host.get_child(0)
	var title: Label = home._title
	var title_rect := title.get_global_rect()
	print("step-1 target rect: ", title_rect)
	var ov: Variant = host._overlay
	if ov != null:
		print("overlay rect=", ov.get_global_rect(), " visible=", ov.visible,
			" filter=", ov.mouse_filter)
	else:
		print("overlay: NULL")

	# Step 1 (GDD §8): "any tap advances" — click the highlighted title.
	var center := title_rect.position + title_rect.size * 0.5
	_push_click(center)
	for i in SETTLE_FRAMES:
		await process_frame
	print("after step-1 click: active=", host.is_active(), " idx=", host._index)
	if int(host._index) != 1:
		print("PROBE FAIL: real tap did not advance step 1 -> 2")
		quit(1)
		return

	# Step 2: an OFF-target tap must be swallowed (still on step 2).
	_push_click(Vector2(30.0, 1250.0))
	for i in SETTLE_FRAMES:
		await process_frame
	print("after off-target click: active=", host.is_active(), " idx=", host._index)
	if int(host._index) != 1:
		print("PROBE FAIL: off-target tap advanced step 2 (should be swallowed)")
		quit(1)
		return

	# Step 2: hit the PLAY button -> FTUE completes and navigation fires.
	var play: Variant = home._ftue_play_button
	var play_rect: Rect2 = play.get_global_rect()
	print("step-2 target rect: ", play_rect)
	_push_click(play_rect.position + play_rect.size * 0.5)
	for i in SETTLE_FRAMES:
		await process_frame
	print("after PLAY click: active=", host.is_active())

	if host.is_active():
		print("PROBE RESULT: STUCK — real input never drove the tutorial")
		quit(1)
	else:
		print("PROBE RESULT: ADVANCED — real input drives the FTUE to completion")
	DirAccess.remove_absolute(tmp)
	quit(0)


func _push_click(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = pos
	down.global_position = pos
	down.pressed = true
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = pos
	up.global_position = pos
	up.pressed = false
	root.push_input(up, true)
