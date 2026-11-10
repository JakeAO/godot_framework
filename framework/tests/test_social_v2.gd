extends GutTest
## Social surface v2 (D5a): MockSocialBackend team-domain semantics (create /
## settings / join requests / by-request flow), the banner system (catalog
## counts + warn-fallback, LUT textures, TeamBannerView rendering, editor
## selection emits) and the SocialScreen v2 flows (invitations section,
## block/unblock, leader-only settings gear, by-request request state,
## create/settings dialogs).

var _host: Control
var _mounted: Array[Node] = []
var _original_save_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_host = Control.new()
	# Phone-sized test host (same doctrine as the screen layout tests).
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func before_each() -> void:
	_original_save_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_save_path = "user://gut_tmp/social_v2_%d.json" % stamp
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	# The manager's mock backend is process-wide (GUT runs one process): reset
	# its state so joins/creates in one test cannot leak into the next.
	if SocialManager._backend is MockSocialBackend:
		(SocialManager._backend as MockSocialBackend).reset()


func after_each() -> void:
	for node in _mounted:
		if is_instance_valid(node):
			node.queue_free()
	_mounted.clear()
	UIManager.close_current_dialog()
	UIManager.clear_toasts()
	SaveSystem.set_save_path(_original_save_path)
	if FileAccess.file_exists(_temp_save_path):
		DirAccess.remove_absolute(_temp_save_path)
	var tmp := _temp_save_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func after_all() -> void:
	if is_instance_valid(_host):
		_host.queue_free()


# --- MockSocialBackend team domain ------------------------------------------------

func test_mock_create_team_validates_and_marks_leader() -> void:
	var mock := MockSocialBackend.new("TEST-0001")
	var empty_name: Dictionary = mock.create_team("", "open", {})
	assert_eq(str(empty_name.get("error", "")), "team_invalid_name", "empty name rejected")
	var long_name: Dictionary = mock.create_team("x".repeat(25), "open", {})
	assert_eq(str(long_name.get("error", "")), "team_invalid_name", "over-long name rejected")
	var bad_mode: Dictionary = mock.create_team("Fine Name", "chaos", {})
	assert_eq(str(bad_mode.get("error", "")), "team_invalid_name", "unknown access mode rejected")

	var ok: Dictionary = mock.create_team("My Team", "by-request", {"base": "base_01"})
	assert_true(bool(ok.get("ok", false)), "valid create accepted")
	var domain: Dictionary = ok.get("team", {})
	assert_eq(str(domain.get("leader_code", "")), "TEST-0001", "creator is the leader")
	assert_true(bool(domain.get("on_team", false)), "creator is on the team")
	assert_eq(str(domain.get("access_mode", "")), "by-request", "access mode persisted")
	assert_eq(str(domain.get("banner_base", "")), "base_01", "banner recipe persisted")

	var again: Dictionary = mock.create_team("Other", "open", {})
	assert_eq(str(again.get("error", "")), "team_already_on_team", "cannot create while on a team")


func test_mock_update_settings_requires_leader() -> void:
	var mock := MockSocialBackend.new("TEST-0001")
	var off_team: Dictionary = mock.update_team_settings({"name": "X"})
	assert_eq(str(off_team.get("error", "")), "team_not_leader", "off-team cannot update settings")

	var teams: Array = mock.search_teams("")
	mock.join_team(str((teams[0] as Dictionary).get("team_id", "")))  # Golden Owls, leader Ada
	var not_leader: Dictionary = mock.update_team_settings({"name": "X"})
	assert_eq(str(not_leader.get("error", "")), "team_not_leader", "non-leader member cannot update settings")

	var mine := MockSocialBackend.new("TEST-0001")
	mine.create_team("Mine", "open", {})
	var updated: Dictionary = mine.update_team_settings({
		"name": "Renamed",
		"access_mode": "by-request",
		"banner_recipe": {"base": "base_02", "icon": "icon_03"},
	})
	assert_true(bool(updated.get("ok", false)), "leader update accepted")
	var domain: Dictionary = mine.fetch_team()
	assert_eq(str(domain.get("team_name", "")), "Renamed", "name updated")
	assert_eq(str(domain.get("access_mode", "")), "by-request", "access mode updated")
	assert_eq(str(domain.get("banner_icon", "")), "icon_03", "banner recipe updated")

	var bad: Dictionary = mine.update_team_settings({"name": ""})
	assert_eq(str(bad.get("error", "")), "team_invalid_name", "invalid name in settings rejected")


func test_mock_icon_scale_roundtrip_through_domain() -> void:
	var mock := MockSocialBackend.new("TEST-0001")
	var created: Dictionary = mock.create_team("Scaled", "open", {
		"base": "base_01", "icon": "icon_02", "icon_scale": 1.25,
	})
	assert_true(bool(created.get("ok", false)), "create with an icon scale accepted")
	var domain: Dictionary = created.get("team", {})
	assert_almost_eq(float(domain.get("banner_icon_scale", 0.0)), 1.25, 0.0001, "the scale persists in the domain shape")
	var updated: Dictionary = mock.update_team_settings({
		"banner_recipe": {"base": "base_01", "icon": "icon_02", "icon_scale": 0.6},
	})
	assert_true(bool(updated.get("ok", false)), "update with an icon scale accepted")
	var after: Dictionary = mock.fetch_team()
	assert_almost_eq(float(after.get("banner_icon_scale", 0.0)), 0.6, 0.0001, "the updated scale persists")

	# Pre-H7 teams carry no scale key -> the classic size (1.0).
	var legacy := MockSocialBackend.new("TEST-0002")
	var teams: Array = legacy.search_teams("")
	legacy.join_team(str((teams[0] as Dictionary).get("team_id", "")))
	var seeded: Dictionary = legacy.fetch_team()
	assert_almost_eq(float(seeded.get("banner_icon_scale", 0.0)), 1.0, 0.0001, "a recipe without icon_scale defaults to the classic size")


func test_mock_join_requests_leader_only_roundtrip() -> void:
	var mock := MockSocialBackend.new("TEST-0001")
	mock.create_team("Gang", "open", {})
	var team_id := (mock)._joined_team_id
	var kofi_code := IdentityService.derive_player_code("mock:Kofi")
	(mock)._join_requests[team_id] = [{"player_code": kofi_code, "name": "Kofi", "ts": 1}]

	var requests: Array = mock.fetch_join_requests()
	assert_eq(requests.size(), 1, "leader sees the pending request")
	assert_eq(str((requests[0] as Dictionary).get("player_code", "")), kofi_code, "request carries the requester code")

	var approved: Dictionary = mock.respond_join_request(kofi_code, true)
	assert_true(bool(approved.get("ok", false)), "approve accepted")
	var domain: Dictionary = mock.fetch_team()
	assert_true(((domain.get("members", []) as Array)).has("Kofi"), "approved requester added to the roster")
	assert_eq((mock).fetch_join_requests(), [], "request consumed after approve")

	var unknown: Dictionary = mock.respond_join_request("OWL-9999", true)
	assert_false(bool(unknown.get("ok", false)), "unknown request rejected")

	# A non-leader member sees no requests.
	var other := MockSocialBackend.new("TEST-0002")
	var teams: Array = other.search_teams("")
	other.join_team(str((teams[0] as Dictionary).get("team_id", "")))
	assert_eq(other.fetch_join_requests(), [], "non-leader gets an empty request list")


func test_mock_request_join_by_request_flow() -> void:
	var mock := MockSocialBackend.new("TEST-0001")
	var teams: Array = mock.search_teams("")
	var open_id := ""
	var request_id := ""
	for team in teams:
		var t := team as Dictionary
		if str(t.get("access_mode", "")) == "open":
			open_id = str(t.get("team_id", ""))
		else:
			request_id = str(t.get("team_id", ""))

	var on_open: Dictionary = mock.request_join(open_id)
	assert_eq(str(on_open.get("error", "")), "team_open", "requesting an open team is rejected")

	var ok: Dictionary = mock.request_join(request_id)
	assert_true(bool(ok.get("ok", false)), "request to a by-request team accepted")
	assert_true(bool(ok.get("pending", false)), "request marked pending")

	var dup: Dictionary = mock.request_join(request_id)
	assert_eq(str(dup.get("error", "")), "team_request_pending", "duplicate request rejected")

	var join: Dictionary = mock.join_team(request_id)
	assert_eq(str(join.get("error", "")), "team_by_request", "direct join of a by-request team rejected")


# --- Banner system ------------------------------------------------------------------

func test_banner_catalog_counts_ids_and_paths() -> void:
	assert_eq(TeamBannerCatalog.bases().size(), TeamBannerCatalog.BASE_COUNT, "90 base entries")
	assert_eq(TeamBannerCatalog.icons().size(), TeamBannerCatalog.ICON_COUNT, "90 icon entries")
	assert_eq(TeamBannerCatalog.luts().size(), TeamBannerCatalog.LUT_COUNT, "48 palette entries")
	for entry in TeamBannerCatalog.bases():
		assert_true(FileAccess.file_exists(str((entry as Dictionary).get("path", ""))), "base %s exists on disk" % str(entry.get("id", "")))
	for entry in TeamBannerCatalog.icons():
		assert_true(FileAccess.file_exists(str((entry as Dictionary).get("path", ""))), "icon %s exists on disk" % str(entry.get("id", "")))
	for entry in TeamBannerCatalog.luts():
		var colors: Array = (entry as Dictionary).get("colors", [])
		assert_eq(colors.size(), TeamBannerCatalog.LUT_COLORS, "palette %s has 16 colors" % str(entry.get("id", "")))


func test_banner_catalog_unknown_id_warns_and_falls_back() -> void:
	var base: Dictionary = TeamBannerCatalog.find_base("nope")
	assert_eq(str(base.get("id", "")), str(TeamBannerCatalog.bases()[0].get("id", "")), "unknown base falls back to the first entry")
	assert_push_warning("base", "unknown base id warns")
	var icon: Dictionary = TeamBannerCatalog.find_icon("nope")
	assert_eq(str(icon.get("id", "")), str(TeamBannerCatalog.icons()[0].get("id", "")), "unknown icon falls back to the first entry")
	assert_push_warning("icon", "unknown icon id warns")
	var lut: Dictionary = TeamBannerCatalog.find_lut("nope")
	assert_eq(str(lut.get("id", "")), str(TeamBannerCatalog.luts()[0].get("id", "")), "unknown lut falls back to the first palette")
	assert_push_warning("lut", "unknown lut id warns")


func test_banner_lut_texture_matches_palette() -> void:
	var entry: Dictionary = TeamBannerCatalog.luts()[0]
	var tex := TeamBannerCatalog.get_lut_texture(str(entry.get("id", "")))
	assert_true(tex is ImageTexture, "LUT resolves to an image texture")
	var img := (tex as ImageTexture).get_image()
	assert_eq(img.get_size(), Vector2i(TeamBannerCatalog.LUT_COLORS, 1), "palette strip is 16x1")
	var colors: Array = entry.get("colors", [])
	# The strip is stored RGB8, so compare with a 1/255 quantization tolerance.
	_assert_color_close(img.get_pixel(0, 0), (colors[0] as Color), "first pixel matches the palette's first color")
	_assert_color_close(img.get_pixel(15, 0), (colors[15] as Color), "last pixel matches the palette's last color")


func test_banner_view_full_recipe_renders_layers() -> void:
	var view := TeamBannerView.new()
	view.custom_minimum_size = Vector2(48, 96)
	_host.add_child(view)
	_mounted.append(view)
	view.setup({"base": "base_01", "icon": "icon_01", "base_lut": "lut_01", "icon_lut": "lut_02"})
	await _settle(3)
	assert_true(view._base_layer.visible, "base layer visible with a full recipe")
	assert_true(view._icon_layer.visible, "icon layer visible with a full recipe")
	assert_false(view._fallback_chip.visible, "fallback chip hidden with a full recipe")
	assert_not_null(view._base_layer.texture, "base texture loaded")
	assert_not_null(view._icon_layer.texture, "icon texture loaded")


func test_banner_view_empty_recipe_shows_fallback_chip() -> void:
	var view := TeamBannerView.new()
	view.custom_minimum_size = Vector2(32, 64)
	_host.add_child(view)
	_mounted.append(view)
	view.setup({}, Color.MAGENTA)
	await _settle(2)
	assert_true(view._fallback_chip.visible, "chip visible for an empty recipe")
	assert_eq(view._fallback_chip.color, Color.MAGENTA, "chip uses the fallback color")
	assert_false(view._base_layer.visible, "base layer hidden without a recipe")
	assert_false(view._icon_layer.visible, "icon layer hidden without a recipe")


func test_banner_view_layers_stay_pinned_after_recipe() -> void:
	# Regression (2026-11-07 on-device report): with the default TextureRect
	# expand mode the MINIMUM size tracks the texture (256×512 bases), which
	# overrides the full-rect anchor pinning — the banner overflowed its host
	# and scaled up as soon as a background was selected.
	var view := TeamBannerView.new()
	view.custom_minimum_size = Vector2(48, 96)
	_host.add_child(view)
	_mounted.append(view)
	await _settle(2)
	view.setup({"base": "base_01", "icon": "icon_03", "base_lut": "lut_01", "icon_lut": "lut_02"})
	await _settle(2)
	assert_eq(view._base_layer.get_global_rect(), view.get_global_rect(), "base layer pinned full-rect (texture size must not override anchors)")
	# Epsilon: the engine's anchor math and this expression don't always agree in
	# the last float bit.
	assert_almost_eq(view._icon_layer.size.x, view.size.x * 0.4, 0.01, "icon layer width at anchor span")
	assert_almost_eq(view._icon_layer.size.y, view.size.y * 0.5, 0.01, "icon layer height at anchor span")


func test_banner_view_icon_scale_rederives_anchors() -> void:
	var view := TeamBannerView.new()
	view.custom_minimum_size = Vector2(48, 96)
	_host.add_child(view)
	_mounted.append(view)
	await _settle(2)
	view.setup({"base": "base_01", "icon": "icon_01"})
	await _settle(2)
	assert_almost_eq(view._icon_layer.anchor_left, 0.3, 0.0001, "no scale key keeps the classic left anchor")
	assert_almost_eq(view._icon_layer.anchor_top, 0.25, 0.0001, "no scale key keeps the classic top anchor")
	assert_almost_eq(view._icon_layer.anchor_right, 0.7, 0.0001, "no scale key keeps the classic right anchor")
	assert_almost_eq(view._icon_layer.anchor_bottom, 0.75, 0.0001, "no scale key keeps the classic bottom anchor")

	view.setup({"base": "base_01", "icon": "icon_01", "icon_scale": 0.5})
	await _settle(2)
	assert_almost_eq(view._icon_layer.anchor_left, 0.4, 0.0001, "min scale shrinks toward center (left)")
	assert_almost_eq(view._icon_layer.anchor_top, 0.375, 0.0001, "min scale shrinks toward center (top)")
	assert_almost_eq(view._icon_layer.size.x, view.size.x * 0.2, 0.01, "layer width follows the scaled span")

	view.setup({"base": "base_01", "icon": "icon_01", "icon_scale": 1.5})
	await _settle(2)
	assert_almost_eq(view._icon_layer.anchor_left, 0.2, 0.0001, "max scale grows from center (left)")
	assert_almost_eq(view._icon_layer.anchor_top, 0.125, 0.0001, "max scale grows from center (top)")
	assert_almost_eq(view._icon_layer.size.y, view.size.y * 0.75, 0.01, "layer height follows the scaled span")

	view.setup({"base": "base_01", "icon": "icon_01", "icon_scale": 99.0})
	await _settle(2)
	assert_almost_eq(view._icon_layer.anchor_left, 0.2, 0.0001, "an out-of-range scale clamps to the max")
	view.setup({"base": "base_01", "icon": "icon_01", "icon_scale": -3.0})
	await _settle(2)
	assert_almost_eq(view._icon_layer.anchor_left, 0.4, 0.0001, "a sub-range scale clamps to the min")


func test_banner_editor_setup_seeds_without_emit_and_selection_emits() -> void:
	var editor := TeamBannerEditor.new()
	_host.add_child(editor)
	_mounted.append(editor)
	await _settle(2)
	watch_signals(editor)
	editor.setup({"base": "base_03", "icon": "icon_05"})
	assert_signal_not_emitted(editor, "recipe_changed", "setup seeds the selection without emitting")
	var base_buttons: Array = editor._base_buttons
	base_buttons[7].emit_signal("toggled", true)
	assert_signal_emitted(editor, "recipe_changed", "selecting a base emits recipe_changed")
	assert_eq(editor.get_recipe(), {"base": "base_08", "icon": "icon_05"}, "recipe reflects the new selection")


func test_banner_editor_strips_are_radio_groups_with_pass_filter() -> void:
	var editor := TeamBannerEditor.new()
	_host.add_child(editor)
	_mounted.append(editor)
	await _settle(2)
	# One ButtonGroup per strip = radio behavior (tapping a new option releases
	# the previous one — on-device bug: all tapped options stayed selected).
	assert_not_null(editor._base_buttons[0].button_group, "base thumbnails carry a button group")
	for b in editor._base_buttons:
		assert_same(b.button_group, editor._base_group, "all base thumbnails share one group")
	for b in editor._icon_buttons:
		assert_same(b.button_group, editor._icon_group, "all icon thumbnails share one group")
	for b in editor._base_lut_buttons:
		assert_same(b.button_group, editor._base_lut_group, "base LUT swatches share one group")
	for b in editor._icon_lut_buttons:
		assert_same(b.button_group, editor._icon_lut_group, "icon LUT swatches share one group")
	assert_false(editor._base_group == editor._icon_group, "strips use distinct groups")
	editor._base_buttons[0].set_pressed(true)
	assert_true(editor._base_buttons[0].button_pressed, "first base thumbnail pressed")
	editor._base_buttons[3].set_pressed(true)
	assert_false(editor._base_buttons[0].button_pressed, "group released the previous selection")
	assert_true(editor._base_buttons[3].button_pressed, "new selection stays pressed")
	# PASS filter: ScrollContainer drives drag-scrolling from press/motion events
	# (emulated mouse on touch devices); STOP buttons swallow those gestures and
	# the strips became unscrollable by touch.
	for group_buttons in [editor._base_buttons, editor._icon_buttons, editor._base_lut_buttons, editor._icon_lut_buttons]:
		for b in group_buttons:
			var button := b as Button
			assert_eq(button.mouse_filter, Control.MOUSE_FILTER_PASS, "thumbnail passes events through to the strip")


func test_banner_editor_scale_slider_seeds_and_emits() -> void:
	var editor := TeamBannerEditor.new()
	_host.add_child(editor)
	_mounted.append(editor)
	await _settle(2)
	assert_not_null(editor._scale_slider, "the icon-size slider exists")
	assert_eq(editor._scale_slider.min_value, TeamBannerView.ICON_SCALE_MIN, "slider range starts at the view min")
	assert_eq(editor._scale_slider.max_value, TeamBannerView.ICON_SCALE_MAX, "slider range ends at the view max")

	editor.setup({"base": "base_01", "icon_scale": 1.3})
	assert_almost_eq(editor._scale_slider.value, 1.3, 0.001, "setup seeds the slider from the recipe without emitting")
	editor.setup({"icon_scale": 42.0})
	assert_almost_eq(editor._scale_slider.value, TeamBannerView.ICON_SCALE_MAX, 0.001, "an out-of-range seeded scale clamps to the max")

	watch_signals(editor)
	editor._scale_slider.set_value(0.7)
	assert_signal_emitted(editor, "recipe_changed", "moving the slider emits recipe_changed")
	assert_almost_eq(float(editor.get_recipe().get("icon_scale", 0.0)), 0.7, 0.001, "the recipe carries the new scale")


# --- SocialScreen v2 flows --------------------------------------------------------------

func test_screen_invitations_section_shows_seeded_invite() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	assert_true(screen._invitations_section.visible, "invitations section visible with a seeded invite")
	assert_eq(screen._invitations_list.get_child_count(), 1, "one pending invitation row")
	var hbox: HBoxContainer = (screen._invitations_list.get_child(0) as PanelContainer).get_child(0)
	assert_eq(hbox.get_child_count(), 3, "received row has name + accept + reject")
	assert_eq(str((hbox.get_child(1) as Button).text), tr("social_accept"), "first action is Accept")
	assert_eq(str((hbox.get_child(2) as Button).text), tr("social_reject"), "second action is Reject")


func test_screen_accept_invitation_adds_friend() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	var mia_code := IdentityService.derive_player_code("mock:Mia")
	await screen._on_respond_invitation_pressed(mia_code, true)
	assert_false(screen._invitations_section.visible, "no pending invitations after accept")
	assert_eq(screen._friends_list.get_child_count(), 4, "Mia joins the friends list")
	var mia_found := false
	for row in screen._friends_list.get_children():
		var name_label: Label = ((row as PanelContainer).get_child(0) as HBoxContainer).get_child(1).get_child(0)
		if str(name_label.text) == "Mia":
			mia_found = true
	assert_true(mia_found, "Mia's friend row rendered")


func test_screen_block_and_unblock_roundtrip() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	assert_false(screen._blocked_section.visible, "no blocked users initially")
	var ada_code := IdentityService.derive_player_code("mock:Ada")
	await screen._on_block_pressed(ada_code)
	assert_true(screen._blocked_section.visible, "blocked section appears after block")
	assert_eq(screen._friends_list.get_child_count(), 2, "blocking removes the friend row")
	assert_eq(screen._blocked_list.get_child_count(), 1, "one blocked row")
	var unblock_button: Button = ((screen._blocked_list.get_child(0) as PanelContainer).get_child(0) as HBoxContainer).get_child(1)
	assert_eq(str(unblock_button.text), tr("social_unblock"), "blocked row offers Unblock")
	await screen._on_unblock_pressed(ada_code)
	assert_false(screen._blocked_section.visible, "unblock clears the section")


func test_screen_settings_gear_leader_only() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	screen._on_join_pressed(teams[0])  # Golden Owls — leader is Ada, not the local player
	await _settle(1)
	assert_true(screen._team_content.visible, "team content visible after join")
	assert_false(screen._settings_button.visible, "gear hidden for a non-leader member")

	await SocialManager.leave_team()
	var created: Dictionary = await SocialManager.create_team("Mine", "open", {})
	assert_true(bool(created.get("ok", false)), "create accepted")
	await _settle(1)
	assert_true(screen._settings_button.visible, "gear visible for the leader")


func test_screen_by_request_row_requests_then_disables() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	var foxes_id := ""
	for team in teams:
		if str(team.get("name", "")) == "Emerald Foxes":
			foxes_id = str(team.get("team_id", ""))
	screen._search_mode.selected = 1
	await screen._refresh_results()
	var row := _find_team_row(screen, "Emerald Foxes")
	assert_not_null(row, "by-request team row found")
	var button: Button = ((row as PanelContainer).get_child(0) as HBoxContainer).get_child(2)
	assert_eq(str(button.text), tr("social_request"), "by-request row offers Request")
	assert_false(button.disabled, "request button enabled initially")

	await screen._on_request_join_pressed(foxes_id)
	assert_eq(str(SaveSystem.get_value("team", "requested_team_id", "")), foxes_id, "requested team id persisted")
	assert_true(screen._request_sent_label.visible, "request-sent label shown off-team")
	var row_after := _find_team_row(screen, "Emerald Foxes")
	var button_after: Button = ((row_after as PanelContainer).get_child(0) as HBoxContainer).get_child(2)
	assert_true(button_after.disabled, "row disabled while a request is pending")
	assert_eq(str(button_after.text), tr("team_request_sent"), "row shows the sent state")


func test_screen_create_dialog_creates_team() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	screen._open_create_dialog()
	assert_true(UIManager.is_dialog_open(), "create dialog opened")
	var panel := (UIManager.dialog_host as DialogHost)._panel
	var content: VBoxContainer = (panel.get_child(0) as VBoxContainer).get_child(1)
	var name_edit: LineEdit = (content.get_child(0) as HBoxContainer).get_child(1)
	name_edit.text = "New Crew"
	var editor := content.get_child(2) as TeamBannerEditor
	editor._base_buttons[2].emit_signal("toggled", true)
	var primary: Button = (content.get_child(3) as HBoxContainer).get_child(2)
	primary.emit_signal("pressed")
	await _settle(2)
	assert_false(UIManager.is_dialog_open(), "dialog closed after create")
	assert_eq(SaveSystem.get_value("team", "on_team", false), true, "create wrote the team domain")
	assert_eq(str(SaveSystem.get_value("team", "team_name", "")), "New Crew", "created team name persisted")
	assert_eq(str(SaveSystem.get_value("team", "banner_base", "")), "base_03", "picked banner base persisted")
	assert_true(screen._team_content.visible, "team tab now shows on-team content")


func test_screen_settings_dialog_saves_changes() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	var created: Dictionary = await SocialManager.create_team("Original", "open", {})
	assert_true(bool(created.get("ok", false)), "create accepted")
	await _settle(1)
	screen._open_settings_dialog()
	assert_true(UIManager.is_dialog_open(), "settings dialog opened")
	var panel := (UIManager.dialog_host as DialogHost)._panel
	var content: VBoxContainer = (panel.get_child(0) as VBoxContainer).get_child(1)
	var name_edit: LineEdit = (content.get_child(0) as HBoxContainer).get_child(1)
	assert_eq(str(name_edit.text), "Original", "settings prefill the current name")
	name_edit.text = "Renamed"
	var primary: Button = (content.get_child(5) as HBoxContainer).get_child(2)
	primary.emit_signal("pressed")
	await _settle(2)
	assert_false(UIManager.is_dialog_open(), "dialog closed after save")
	assert_eq(str(SaveSystem.get_value("team", "team_name", "")), "Renamed", "settings saved the new name")


func test_screen_settings_dialog_join_request_approve() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle(2)
	await SocialManager.create_team("Gang", "open", {})
	await _settle(1)
	var mock := SocialManager.get_backend() as MockSocialBackend
	var team_id := (mock)._joined_team_id
	var kofi_code := IdentityService.derive_player_code("mock:Kofi")
	(mock)._join_requests[team_id] = [{"player_code": kofi_code, "name": "Kofi", "ts": 1}]

	screen._open_settings_dialog()
	await _settle(1)
	var panel := (UIManager.dialog_host as DialogHost)._panel
	var content: VBoxContainer = (panel.get_child(0) as VBoxContainer).get_child(1)
	var requests_box: VBoxContainer = content.get_child(4)
	assert_eq(requests_box.get_child_count(), 1, "pending request listed in settings")
	var approve: Button = ((requests_box.get_child(0) as PanelContainer).get_child(0) as HBoxContainer).get_child(1)
	approve.emit_signal("pressed")
	await _settle(2)
	assert_eq(requests_box.get_child_count(), 0, "request consumed after approve")
	var members: Array = SaveSystem.get_domain("team").get("members", [])
	assert_true(members.has("Kofi"), "approved requester added to the roster")


# --- Helpers ------------------------------------------------------------------------

func _mount(screen: SocialScreen) -> SocialScreen:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


## Finds a search-result team row by its name label; null when absent. Row
## shape: Panel -> HBox [banner, VBox(info), action button].
func _find_team_row(screen: SocialScreen, team_name: String) -> PanelContainer:
	for child in screen._results_list.get_children():
		var row := child as PanelContainer
		if row == null or row.get_child_count() < 1:
			continue
		var hbox := row.get_child(0) as HBoxContainer
		if hbox == null or hbox.get_child_count() < 2:
			continue
		var info := hbox.get_child(1) as VBoxContainer
		if info == null or info.get_child_count() == 0:
			continue
		var name_label := info.get_child(0) as Label
		if name_label != null and str(name_label.text) == team_name:
			return row
	return null


func _settle(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame


func _assert_color_close(actual: Color, expected: Color, message: String) -> void:
	var delta := 1.0 / 128.0
	assert_almost_eq(actual.r, expected.r, delta, message + " (r)")
	assert_almost_eq(actual.g, expected.g, delta, message + " (g)")
	assert_almost_eq(actual.b, expected.b, delta, message + " (b)")
