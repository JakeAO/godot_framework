extends SceneTree
## Minimal repro: does set_anchors_preset() called in _ready (node already in
## tree) behave differently from setting it before add_child?
## Run: ~/tools/godot --headless --path . -s res://tools/probe_minimal.gd


class LatePin extends Control:
	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)


func _initialize() -> void:
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	for i in 10:
		await process_frame
	print("root size   ", root.size)
	print("host size   ", host.size)

	var early := Control.new()
	early.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(early)

	var late := LatePin.new()
	host.add_child(late)

	for i in 10:
		await process_frame
	print("early (preset before add) size=", early.size, " off_r/b=", early.offset_right, early.offset_bottom)
	print("late  (preset in _ready)  size=", late.size, " off_r/b=", late.offset_right, late.offset_bottom)

	# Does a direct offset write fix the late one?
	late.offset_right = 0.0
	late.offset_bottom = 0.0
	await process_frame
	print("late after offset zero    size=", late.size, " off_r/b=", late.offset_right, late.offset_bottom)
	quit(0)
