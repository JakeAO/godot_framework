extends SceneTree
## Layout probe: boots the real main scene headless, lets layout settle, then
## prints global rects of shell chrome + Home/Profile/Social containers so
## anchoring can be verified without a display.
## Run: ~/tools/godot --headless --path . -s res://tools/probe_layout.gd
## NOTE: autoloads are reached via root.get_node() because the -s entry
## script compiles before autoload identifiers resolve.

const SETTLE_FRAMES: int = 30


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var main := packed.instantiate()
	root.add_child(main)
	for i in SETTLE_FRAMES:
		await process_frame
	_report_home()

	var event_bus: Node = root.get_node("EventBus")
	event_bus.navigation_requested.emit(&"social")
	for i in SETTLE_FRAMES:
		await process_frame
	# NOTE: _report_tabbed_screen awaits internally (tab-press simulation), so
	# it MUST be awaited here — otherwise navigation to the next screen fires
	# while the report is suspended and detaches the screen mid-report.
	await _report_tabbed_screen("social")

	event_bus.navigation_requested.emit(&"profile")
	for i in SETTLE_FRAMES:
		await process_frame
	await _report_tabbed_screen("profile")
	quit(0)


func _report_home() -> void:
	print("== home ==")
	var shell: Control = _shell()
	if not is_instance_valid(shell):
		return
	_print_rect("shell         ", shell)
	var content_host: Control = shell.content_host
	_print_rect("content_host  ", content_host)
	if content_host.get_child_count() > 0:
		var screen: Control = content_host.get_child(0)
		_print_rect("home_screen   ", screen)
		if screen.get_child_count() > 0:
			var margin: Control = screen.get_child(0)
			_print_rect("margin        ", margin)
			if margin.get_child_count() > 0:
				var center: Control = margin.get_child(0)
				_print_rect("center_box    ", center)
				if center.get_child_count() > 0:
					_print_rect("ladder_vbox   ", center.get_child(0))
	# First offer widget (should be the animated piggy-bank, 56x56 host).
	var items: Control = shell._right_items
	if is_instance_valid(items) and items.get_child_count() > 0:
		var slot: Control = items.get_child(0)
		if slot.get_child_count() > 0:
			var center: Control = slot.get_child(0)
			if center.get_child_count() > 0:
				var host: Control = center.get_child(0)
				print("offer_widget  ", host.get_class(), " ", host.size, " at ", host.get_global_rect())


func _report_tabbed_screen(screen_id: String) -> void:
	print("== %s ==" % screen_id)
	var shell: Control = _shell()
	if not is_instance_valid(shell):
		return
	var content_host: Control = shell.content_host
	if content_host.get_child_count() == 0:
		return
	var screen: Control = content_host.get_child(0)
	_print_rect("screen        ", screen)
	var pages: Array = screen._pages
	for i in pages.size():
		var page: Control = pages[i]
		_print_rect("page[%d]      " % i, page)
	if String(screen_id) == "social":
		# Simulate the user pressing the Search tab: containers inside hidden
		# subtrees are not sorted, so sizes only make sense once visible.
		print("screen pos before press: ", screen.position, " offsets: (", screen.offset_left, ",", screen.offset_top, ")")
		var buttons: Array = screen._tab_buttons
		buttons[2].emit_signal("pressed")
		for i in SETTLE_FRAMES:
			await process_frame
		print("screen pos after press:  ", screen.position, " offsets: (", screen.offset_left, ",", screen.offset_top, ")")
		print("screen parent:           ", screen.get_parent(), " host children: ", shell.content_host.get_child_count())
		print("-- after pressing search tab --")
		_print_rect("shell         ", shell)
		_print_rect("content_host  ", shell.content_host)
		_print_rect("screen        ", screen)
		for i in pages.size():
			_print_rect("page[%d]      " % i, pages[i])
		var edit: Control = screen._search_edit
		if is_instance_valid(edit):
			print("search_edit   ", edit.size, " at ", edit.get_global_rect())


func _dump(node: Control, depth: int) -> void:
	var indent := "\t".repeat(depth)
	print(
		indent, node.get_class(), " size=", node.size,
		" min=", node.get_combined_minimum_size()
	)
	if depth >= 4:
		return
	for child in node.get_children():
		if child is Control:
			_dump(child, depth + 1)


func _shell() -> Control:
	var screen_manager: Node = root.get_node("ScreenManager")
	return screen_manager._shell


func _print_rect(label: String, node: Control) -> void:
	print(
		label, " ", node.get_global_rect(),
		" anchors=(%s,%s)-(%s,%s)" % [node.anchor_left, node.anchor_top, node.anchor_right, node.anchor_bottom]
	)
