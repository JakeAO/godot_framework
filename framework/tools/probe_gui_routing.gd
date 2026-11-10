extends SceneTree
## Minimal repro: does root.push_input() route a click to a STOP Control that
## lives on a high CanvasLayer (like UIManager's hosts)? Prints which control's
## _gui_input actually fires. Run:
## ~/tools/godot --headless --path . -s res://tools/probe_gui_routing.gd

class Spy extends Control:
	var name_tag := ""
	func _gui_input(event: InputEvent) -> void:
		print("  _gui_input fired on: ", name_tag, " event=", event.get_class(), " pos=", event.get_position())


func _initialize() -> void:
	# Layer-0 STOP control (like a screen element).
	var base := Spy.new()
	base.name_tag = "BASE(layer0)"
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(base)

	# High CanvasLayer with a full-rect STOP child (like the tutorial overlay).
	var layer := CanvasLayer.new()
	layer.layer = 10
	root.add_child(layer)
	var top := Spy.new()
	top.name_tag = "TOP(canvaslayer10)"
	top.set_anchors_preset(Control.PRESET_FULL_RECT)
	top.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(top)

	for i in 5:
		await process_frame

	print("root size: ", root.size)
	print("pushing click at (640, 426):")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = Vector2(640.0, 426.0)
	down.global_position = Vector2(640.0, 426.0)
	down.pressed = true
	root.push_input(down, true)
	await process_frame

	print("done")
	quit(0)
