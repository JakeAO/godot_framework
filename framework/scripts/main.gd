class_name Main
extends Control
## Root scene script. Runs the boot sequence (save -> settings -> locale ->
## config -> analytics -> ads -> screens -> audio) and forwards window
## visibility into EventBus so core systems can react to app lifecycle.


func _ready() -> void:
	_boot()
	get_tree().root.visibility_changed.connect(_on_root_visibility_changed)


# --- Boot ------------------------------------------------------------------------

func _boot() -> void:
	SaveSystem.load_save()
	SettingsManager.init_from_save()
	LocalizationManager.init()
	RemoteConfig.fetch()
	# Cross-device save (TDD §3.16): attach the transport and fetch on app ready.
	# Real mode: OnlineService already wired NakamaSaveSyncBackend at autoload time
	# and triggers the first fetch after the first verified connection (§3.18).
	if not OnlineService.is_real_mode():
		SaveSystem.set_sync_backend(MockSaveSyncBackend.new())
		SaveSystem.fetch_synced_domains()
	Analytics.start_session()
	AdManager.start()
	ScreenManager.attach(self)
	AudioManager.play_bgm(AudioManager.BGM_MENU)
	EventBus.app_ready.emit()
	_maybe_start_probe()


# --- Dev-only visual probe (tools/visual_probe.sh) ---------------------------------
## Pass `probe=<target>` as a user arg: navigate to the screen, optionally open
## the banner-create dialog, then save a viewport screenshot to user:// and quit.
## No args = normal boot, zero overhead. Requires a real renderer (Xvfb + GL).

const PROBE_TARGETS: Array[String] = ["home", "social", "profile", "settings", "shop", "banner_create", "text_dialog", "banner_debug", "zone_daily_gift", "zone_piggy", "zone_streak", "zone_claim", "zone_tournament", "gift_pile", "gift_pile_danger"]


func _maybe_start_probe() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("probe="):
			var target := arg.substr(6)
			if PROBE_TARGETS.has(target):
				_run_probe(target)
			else:
				push_warning("Main: unknown probe target '%s' (use one of %s)" % [target, str(PROBE_TARGETS)])
			return


func _run_probe(target: String) -> void:
	await get_tree().create_timer(0.5).timeout
	match target:
		"social", "profile", "settings", "shop":
			EventBus.navigation_requested.emit(StringName(target))
			await get_tree().create_timer(0.5).timeout
		"banner_create":
			EventBus.navigation_requested.emit(ScreenIds.SOCIAL)
			await get_tree().create_timer(0.5).timeout
			var screen := ScreenManager.get_current_screen()
			if screen is SocialScreen:
				screen._open_create_dialog()
			else:
				push_warning("Main: probe banner_create — social screen not active")
			await get_tree().create_timer(0.5).timeout
		"text_dialog":
			UIManager.show_text_dialog("Probe Title", "The quick brown fox jumps over the lazy dog. ".repeat(4))
			await get_tree().create_timer(0.5).timeout
		"zone_daily_gift", "zone_piggy", "zone_streak", "zone_claim", "zone_tournament":
			_open_zone_dialog_probe(target)
			await get_tree().create_timer(0.8).timeout
		"gift_pile", "gift_pile_danger":
			_seed_gift_pile_probe(target == "gift_pile_danger")
			EventBus.navigation_requested.emit(ScreenIds.GIFT_PILE)
			await get_tree().create_timer(0.5).timeout
		"banner_debug":
			EventBus.navigation_requested.emit(ScreenIds.SOCIAL)
			await get_tree().create_timer(0.5).timeout
			var screen := ScreenManager.get_current_screen()
			if screen is SocialScreen:
				screen._open_create_dialog()
			await get_tree().create_timer(0.8).timeout
			_print_banner_layout_debug()
			# Taps first: the routing test's wheel check leaves the strip scrolled,
			# which pushes btn0/btn1 out of the visible window.
			await _test_thumb_tap()
			_dump_selected_layout()
			await _test_drag_routing()
			var cancel := _find_button_by_text(UIManager.dialog_host, "Cancel")
			if cancel != null:
				print("DBG tapping Cancel at ", cancel.get_global_rect().get_center())
				await _tap_at(cancel.get_global_rect().get_center())
			else:
				print("DBG Cancel button not found; closing programmatically")
				UIManager.close_current_dialog()
			await get_tree().create_timer(0.5).timeout
			_print_post_close_state()
	var img := get_viewport().get_texture().get_image()
	var path := "user://probe_%s.png" % target
	img.save_png(path)
	print("PROBE_SAVED ", ProjectSettings.globalize_path(path))
	get_tree().quit()


func _open_zone_dialog_probe(target: String) -> void:
	var kind := ""
	var entry: Dictionary = {}
	match target:
		"zone_daily_gift":
			kind = ZoneDialog.DAILY_GIFT_KIND
			entry = {"title": "Daily Gift", "icon": "gift"}
		"zone_piggy":
			kind = ZoneDialog.PIGGY_BANK_KIND
			entry = {"title": "Piggy Bank", "icon": "bank"}
		"zone_streak":
			kind = ZoneDialog.STREAK_KIND
			entry = {"title": "Streak Bonus", "icon": "crown"}
		"zone_claim":
			kind = ZoneDialog.CLAIM_KIND
			entry = {"title": "Booster Pack", "icon": "booster", "reward_amount": 5, "reward_currency": "gems"}
		"zone_tournament":
			# Mirrors the remote_config.json tournament_weekend event shape; in mock
			# mode the dialog renders its offline state (TournamentService inert).
			kind = ZoneDialog.TOURNAMENT_KIND
			entry = {
				"id": "tournament_weekend",
				"title": "Weekend Tournament",
				"icon": "trophy",
				"kind": TournamentService.KIND_SOLO,
				"rewards": [
					{"min_rank": 1, "max_rank": 1, "currency": "gems", "amount": 25},
					{"min_rank": 2, "max_rank": 3, "currency": "gems", "amount": 10},
				],
			}
		"zone_leaderboards":
			# Mirrors the remote_config.json evergreen leaderboards event; in mock
			# mode the dialog renders its offline state (LeaderboardService inert).
			kind = ZoneDialog.LEADERBOARDS_KIND
			entry = {"id": "leaderboards", "title": "Leaderboards", "icon": "crown", "kind": ZoneDialog.LEADERBOARDS_KIND}
		"zone_matchmaking":
			# Mirrors the remote_config.json evergreen matchmaking event; in mock
			# mode the dialog renders its offline state (MatchmakingService inert).
			kind = ZoneDialog.MATCHMAKING_KIND
			entry = {"id": "matchmaking", "title": "Matchmaking", "icon": "team", "kind": ZoneDialog.MATCHMAKING_KIND}
	var dialog := ZoneDialog.new()
	dialog.setup(kind, entry, "offer", str(entry.get("icon", "")))
	UIManager.show_dialog(dialog, str(entry.get("title", "")), true, Vector2(400, 0), false)


## Seeds a deterministic mid-run gift pile (hand-built pile — no RNG) so the
## probe shows revealed/covered slots and banked totals; danger=true stops one
## slot below the top so the save/RV/give-up overlay is visible.
func _seed_gift_pile_probe(danger: bool) -> void:
	var pile: Array = [
		{"kind": "coins", "amount": 25},
		{"kind": "gems", "amount": 3},
		{"kind": "cosmetic", "cosmetic": "portrait_icon:gold"},
		{"kind": "coins", "amount": 25},
		{"kind": "fail"},
		{"kind": "gems", "amount": 25},
	]
	var run := {
		"pile": pile,
		"revealed": 5 if danger else 4,
		"banked_coins": 50,
		"banked_gems": 3,
		"danger": danger,
	}
	var domain := SaveSystem.get_domain("gift_pile")
	domain["run"] = run
	SaveSystem.set_domain("gift_pile", domain)
	SaveSystem.save_game()


# --- banner_debug helpers (dev-only diagnostics for the create-team dialog) ----

func _find_banner_editor(node: Node = null) -> TeamBannerEditor:
	if node == null:
		node = get_tree().root
	if node is TeamBannerEditor:
		return node
	for child in node.get_children():
		var found := _find_banner_editor(child)
		if found != null:
			return found
	return null


func _tap_at(point: Vector2) -> void:
	var down := InputEventScreenTouch.new()
	down.pressed = true
	down.index = 0
	down.position = point
	get_tree().root.push_input(down, true)
	await get_tree().process_frame
	var up := InputEventScreenTouch.new()
	up.pressed = false
	up.index = 0
	up.position = point
	get_tree().root.push_input(up, true)
	await get_tree().process_frame


func _find_button_by_text(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for child in node.get_children():
		var found := _find_button_by_text(child, text)
		if found != null:
			return found
	return null


func _first_center_container(node: Node) -> CenterContainer:
	if node is CenterContainer:
		return node
	for child in node.get_children():
		var found := _first_center_container(child)
		if found != null:
			return found
	return null


func _print_banner_layout_debug() -> void:
	print("DBG viewport=", get_viewport().get_visible_rect())
	var host := UIManager.dialog_host
	if not host.is_open():
		print("DBG no dialog open")
		return
	var panel: PanelContainer = host._panel
	print("DBG panel=", panel.get_global_rect())
	var editor := _find_banner_editor()
	if editor == null:
		print("DBG no editor found")
		return
	print("DBG editor=", editor.get_global_rect())
	print("DBG view  =", editor._view.get_global_rect())
	var preview_center := _first_center_container(editor)
	if preview_center != null:
		print("DBG pcenter=", preview_center.get_global_rect())


func _first_scroll_container(node: Node) -> ScrollContainer:
	if node is ScrollContainer:
		return node
	for child in node.get_children():
		var found := _first_scroll_container(child)
		if found != null:
			return found
	return null


## Taps two base thumbnails in sequence: verifies plain selection AND the
## ButtonGroup radio behavior (tapping #2 must release #1). Must run BEFORE
## _test_drag_routing — that test's wheel check leaves the strip scrolled, which
## pushes btn0/btn1 out of the visible window.
func _test_thumb_tap() -> void:
	var editor := _find_banner_editor()
	if editor == null or editor._base_buttons.size() < 2:
		print("DBG tap: no base buttons found")
		return
	var first := editor._base_buttons[0]
	var second := editor._base_buttons[1]
	var sc2 := _first_scroll_container(editor)
	print("DBG tap-prep: h_scroll=", sc2.get_h_scroll() if sc2 != null else -1, " btn0_rect=", first.get_global_rect())
	var got: Array[String] = []
	var on_btn := func(e: InputEvent) -> void:
		got.append(e.get_class())
	first.gui_input.connect(on_btn)
	var tap_pos := first.get_global_rect().get_center()
	print("DBG tap1 at ", tap_pos)
	await _tap_at(tap_pos)
	first.gui_input.disconnect(on_btn)
	print("DBG tap1 events=", str(got), " btn0=", first.button_pressed, " recipe_base=", str(editor.get_recipe().get("base", "")))
	await _tap_at(second.get_global_rect().get_center())
	print("DBG tap2: btn0=", first.button_pressed, " btn1=", second.button_pressed, " recipe_base=", str(editor.get_recipe().get("base", "")))


## After a base+icon selection: dumps every preview-layer rect (the on-device
## bug report says the banner scales up once a background is selected) and
## saves an intermediate screenshot of the selected state.
func _dump_selected_layout() -> void:
	var editor := _find_banner_editor()
	if editor == null:
		print("DBG sel: no editor")
		return
	var view := editor._view
	print("DBG sel: viewport=", get_viewport().get_visible_rect())
	print("DBG sel: view  =", view.get_global_rect(), " min=", view.get_combined_minimum_size())
	print("DBG sel: chip  =", view._fallback_chip.get_global_rect(), " visible=", view._fallback_chip.visible)
	print("DBG sel: base  =", view._base_layer.get_global_rect(), " visible=", view._base_layer.visible, " min=", view._base_layer.get_combined_minimum_size())
	print("DBG sel: icon  =", view._icon_layer.get_global_rect(), " visible=", view._icon_layer.visible, " min=", view._icon_layer.get_combined_minimum_size())
	var img := get_viewport().get_texture().get_image()
	var path := "user://probe_banner_selected.png"
	img.save_png(path)
	print("PROBE_SAVED ", ProjectSettings.globalize_path(path))


func _push_emulated_mouse_button(point: Vector2, pressed: bool) -> void:
	var mb := InputEventMouseButton.new()
	mb.device = InputEvent.DEVICE_ID_EMULATION
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = pressed
	mb.position = point
	mb.global_position = point
	get_tree().root.push_input(mb, true)


func _push_emulated_motion(point: Vector2, relative: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.device = InputEvent.DEVICE_ID_EMULATION
	motion.position = point
	motion.relative = relative
	get_tree().root.push_input(motion, true)


## The engine's drag-scroll path (ScrollContainer.gui_input) is gated on
## DisplayServer.is_touchscreen_available() — false under Xvfb — so the probe
## cannot exercise the scroll itself. It verifies what must be true for it to
## work on a real device instead: (1) press + motion events reach the
## ScrollContainer THROUGH the PASS-filter buttons, (2) a drag ending outside
## any thumbnail does not select one, (3) wheel scrolling still works.
func _test_drag_routing() -> void:
	var editor := _find_banner_editor()
	if editor == null or editor._base_buttons.is_empty():
		print("DBG routing: no editor/buttons")
		return
	var sc := _first_scroll_container(editor)
	if sc == null:
		print("DBG routing: no scroll container")
		return
	var received: Array[String] = []
	var on_gui := func(event: InputEvent) -> void:
		received.append(event.get_class())
	sc.gui_input.connect(on_gui)
	var first := editor._base_buttons[0]
	var recipe_before := str(editor.get_recipe().get("base", ""))
	var start := sc.get_global_rect().position + Vector2(150, 40)
	_push_emulated_mouse_button(start, true)
	await get_tree().process_frame
	for i in range(1, 7):
		_push_emulated_motion(start + Vector2(i * 60.0, 0.0), Vector2(60.0, 0.0))
		await get_tree().process_frame
	_push_emulated_mouse_button(start + Vector2(360.0, 0.0), false)
	await get_tree().process_frame
	sc.gui_input.disconnect(on_gui)
	var counts := {}
	for c in received:
		counts[c] = int(counts.get(c, 0)) + 1
	print("DBG routing: sc got ", str(counts))
	print("DBG routing: spurious btn0=", first.button_pressed, " recipe_before=", recipe_before, " recipe_after=", str(editor.get_recipe().get("base", "")))
	var h_before: int = sc.get_h_scroll()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_RIGHT
	wheel.pressed = true
	wheel.position = start
	wheel.global_position = start
	get_tree().root.push_input(wheel, true)
	await get_tree().process_frame
	print("DBG routing: wheel h_scroll ", h_before, " -> ", sc.get_h_scroll())


func _print_post_close_state() -> void:
	var host := UIManager.dialog_host
	print("DBG post-close: is_open=", host.is_open(), " ui_dialog_open=", UIManager.is_dialog_open())
	for child in host.get_children():
		print("DBG   host child: ", str(child.name), " visible=", child.visible, " filter=", child.mouse_filter)


# --- Lifecycle ---------------------------------------------------------------------

func _on_root_visibility_changed(visible_now: bool) -> void:
	EventBus.visibility_changed.emit(visible_now)
