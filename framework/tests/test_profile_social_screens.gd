extends GutTest
## Screen-level behavior for the tabbed screens: Profile (portrait preview +
## Portrait/Flair/Crown/Stats tabs in a TabContainer, picks persist to the
## save "profile" domain with inline — not toast — feedback per H2) and Social (Friends list,
## Team on/off states with join flow, Search filtering by friend/team mode).
## Also covers layout regressions: main tab pages must fill their
## TabContainer, team sub-pages (still custom toggle bars) must fill their
## host, and the search bar must stretch to the page width.

var _host: Control
var _mounted: Array[BaseScreen] = []
var _original_path: String = ""
var _temp_path: String = ""


func before_all() -> void:
	_host = Control.new()
	# Phone-sized test host: screens are full-rect anchored under it, so their
	# internal layout is computed against a realistic 720x1280 content area.
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/screens_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	# The manager's mock backend is process-wide (GUT runs one process): reset
	# its state so joins/adds in one test cannot leak into the next.
	if SocialManager._backend is MockSocialBackend:
		(SocialManager._backend as MockSocialBackend).reset()
	# Manager-side presence state (TDD §3.25) is also process-wide; clear it so
	# one test's seam pushes cannot leak into the next test's rows.
	SocialManager._reset_caches()


func after_each() -> void:
	for screen in _mounted:
		if is_instance_valid(screen):
			screen.queue_free()
	_mounted.clear()
	# Belt-and-braces (H2: picks no longer toast, but other flows still do):
	# clear any lingering toasts so they cannot leak across files in-process.
	UIManager.clear_toasts()
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func after_all() -> void:
	# Immediate free (not queue_free): GUT's end-of-file unfreed-children
	# check runs before the deferred free would be processed.
	if is_instance_valid(_host):
		_host.free()


# --- Profile --------------------------------------------------------------------

func test_profile_builds_preview_and_four_tabs() -> void:
	var screen := _mount(ProfileScreen.new())
	assert_eq(screen._tabs.get_tab_count(), 4, "four tabs built")
	assert_not_null(screen._portrait_view, "portrait preview built")
	await _settle_layout(2)
	assert_true(screen._pages[0].visible, "first tab page visible by default")
	assert_false(screen._pages[1].visible, "other pages hidden by default")


func test_profile_tab_switching() -> void:
	var screen := _mount(ProfileScreen.new())
	screen._tabs.current_tab = 3
	await _settle_layout(2)
	assert_true(screen._pages[3].visible, "stats page visible after switching to its tab")
	assert_false(screen._pages[0].visible, "portrait page hidden after switching away")
	assert_eq(screen._tabs.current_tab, 3, "tab index reflects the switch")


func test_profile_portrait_pick_persists_without_toast() -> void:
	_seed_owned("portrait_icon:gold")
	var screen := _mount(ProfileScreen.new())
	watch_signals(UIManager.toast_host)
	screen._on_option_tapped(_make_click(Vector2.ZERO), "gold", PortraitView.PROFILE_KEY_ICON)
	assert_eq(SaveSystem.get_value("profile", "portrait_icon", ""), "gold", "pick persisted to the profile domain")
	# H2 toast policy: a pick is the direct effect of the tap — no toast.
	assert_signal_not_emitted(UIManager.toast_host, "toast_shown")


func test_profile_code_hold_copies_with_inline_feedback() -> void:
	var screen := _mount(ProfileScreen.new())
	await _settle_layout(2)
	watch_signals(UIManager.toast_host)
	screen._on_code_long_press()
	# (The clipboard write itself is engine-level and a no-op headless.)
	assert_eq(screen._code_label.text, tr("profile_code_copied"), "inline feedback replaces the code label")
	# H2 toast policy: copying is the direct effect of the hold — no toast.
	assert_signal_not_emitted(UIManager.toast_host, "toast_shown")
	assert_eq(UIManager.toast_host.queued_count(), 0, "no queued toast")
	await get_tree().create_timer(1.4).timeout
	assert_eq(screen._code_label.text, IdentityService.get_player_code(), "label restores the code after the beat")


func test_profile_flair_and_crown_picks() -> void:
	_seed_owned("portrait_flair:ring_blue")
	_seed_owned("portrait_crown:crown_diamond")
	var screen := _mount(ProfileScreen.new())
	screen._on_option_tapped(_make_click(Vector2.ZERO), "ring_blue", PortraitView.PROFILE_KEY_FLAIR)
	screen._on_option_tapped(_make_click(Vector2.ZERO), "crown_diamond", PortraitView.PROFILE_KEY_CROWN)
	assert_eq(SaveSystem.get_value("profile", "portrait_flair", ""), "ring_blue", "flair pick persisted")
	assert_eq(SaveSystem.get_value("profile", "portrait_crown", ""), "crown_diamond", "crown pick persisted")


func test_profile_locked_option_redirects_to_shop() -> void:
	var screen := _mount(ProfileScreen.new())
	watch_signals(EventBus)
	screen._on_option_tapped(_make_click(Vector2.ZERO), "gold", PortraitView.PROFILE_KEY_ICON)
	assert_eq(SaveSystem.get_value("profile", "portrait_icon", ""), "", "locked pick is not persisted")
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.SHOP])


func test_profile_partial_unlock_shows_greyed_progress_bar() -> void:
	var domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	domain["shard_progress"] = {"portrait_icon:gold": 5}
	SaveSystem.set_domain(ShopLogic.SHOP_DOMAIN, domain)
	var screen := _mount(ProfileScreen.new())
	await _settle_layout(2)
	var cell_data: Dictionary = screen._icon_cells["gold"]
	var preview: PortraitView = cell_data["preview"]
	var hint: Label = cell_data["hint"]
	var progress: ProgressBar = cell_data["progress"]
	assert_almost_eq(preview.modulate.a, 0.55, 0.001, "a partially unlocked option is greyed")
	assert_true(progress.visible, "the shard progress bar is visible while partial")
	assert_almost_eq(progress.value, 25.0, 0.01, "the bar shows the unlock percent (5 of 20 shards)")
	assert_eq(hint.text, tr("profile_shard_progress") % [25], "the hint line shows the percent")


func test_profile_zero_percent_shows_no_shard_indicator() -> void:
	var screen := _mount(ProfileScreen.new())
	await _settle_layout(2)
	var cell_data: Dictionary = screen._icon_cells["silver"]
	assert_false((cell_data["progress"] as ProgressBar).visible, "a 0% option shows no shard indicator at all")
	assert_almost_eq((cell_data["preview"] as PortraitView).modulate.a, 0.35, 0.001, "a 0% option keeps the locked dim state")


func test_profile_owned_option_hides_stale_shard_progress() -> void:
	var domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	var owned: Array = domain.get("owned_cosmetics", [])
	owned.append("portrait_icon:gold")
	domain["owned_cosmetics"] = owned
	domain["shard_progress"] = {"portrait_icon:gold": 3}
	SaveSystem.set_domain(ShopLogic.SHOP_DOMAIN, domain)
	var screen := _mount(ProfileScreen.new())
	await _settle_layout(2)
	var cell_data: Dictionary = screen._icon_cells["gold"]
	assert_almost_eq((cell_data["preview"] as PortraitView).modulate.a, 1.0, 0.001, "an owned option renders normal")
	assert_false((cell_data["progress"] as ProgressBar).visible, "stale shard progress never shows on an owned option")


# --- Social ---------------------------------------------------------------------

func test_social_not_on_team_shows_cta() -> void:
	var screen := _mount(SocialScreen.new())
	assert_true(screen._no_team_box.visible, "join CTA visible when not on a team")
	assert_false(screen._team_content.visible, "team content hidden when not on a team")


func test_social_find_team_button_opens_search_tab() -> void:
	var screen := _mount(SocialScreen.new())
	screen._find_team_button.emit_signal("pressed")
	await _settle_layout(2)
	assert_true(screen._pages[2].visible, "search tab opened by the CTA button")


func test_social_join_team_updates_domain_and_header() -> void:
	var screen := _mount(SocialScreen.new())
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	screen._on_join_pressed(teams[0])
	assert_eq(SaveSystem.get_value("team", "on_team", false), true, "join writes the team domain")
	assert_true(screen._team_content.visible, "team content visible after joining")
	assert_false(screen._no_team_box.visible, "CTA hidden after joining")
	assert_eq(screen._team_name_label.text, "Golden Owls", "team header shows the team name")


func test_social_search_filters_friends() -> void:
	var screen := _mount(SocialScreen.new())
	screen._search_edit.text = "ada"
	screen._refresh_results()
	assert_eq(screen._results_list.get_child_count(), 1, "only matching friend listed")


func test_social_search_mode_switches_pool() -> void:
	var screen := _mount(SocialScreen.new())
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	screen._search_mode.selected = 1
	screen._refresh_results()
	assert_eq(screen._results_list.get_child_count(), teams.size(), "all teams listed in team mode")

	screen._search_edit.text = "blue"
	screen._refresh_results()
	assert_eq(screen._results_list.get_child_count(), 1, "team query filters the pool")


func test_social_no_results_label() -> void:
	var screen := _mount(SocialScreen.new())
	screen._search_edit.text = "zzz-no-match"
	screen._refresh_results()
	assert_true(screen._no_results_label.visible, "no-results label shown for empty results")


# --- Chat (realtime per TDD §3.24) -------------------------------------------------

func test_social_chat_subpage_has_send_box() -> void:
	var screen := _mount(SocialScreen.new())
	assert_not_null(screen._chat_input, "chat input built")
	assert_not_null(screen._chat_send_button, "send button built")
	assert_eq(screen._chat_input.placeholder_text, tr("social_chat_hint"), "placeholder localized")


func test_social_chat_send_posts_and_clears() -> void:
	var screen := _mount(SocialScreen.new())
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	screen._on_join_pressed(teams[0])
	screen._tabs.current_tab = 1
	await _settle_layout(2)
	var rows_before: int = screen._chat_list.get_child_count()
	assert_gt(rows_before, 0, "seeded history rendered after joining + opening chat")
	screen._chat_input.text = "hello team"
	await screen._submit_chat()
	assert_eq(screen._chat_input.text, "", "input clears after a successful send")
	assert_eq(screen._chat_list.get_child_count(), rows_before + 1, "sent message renders as a new row")


func test_social_chat_send_ignores_blank_text() -> void:
	var screen := _mount(SocialScreen.new())
	screen._chat_input.text = "   "
	await screen._submit_chat()
	assert_eq(screen._chat_input.text, "   ", "blank text is not posted and the field is untouched")


func test_social_chat_input_gated_offline() -> void:
	var screen := _mount(SocialScreen.new())
	screen._apply_online_gates(false)
	assert_eq(screen._chat_input.focus_mode, Control.FOCUS_NONE, "offline input is unfocusable")
	assert_true(screen._chat_send_button.disabled, "offline send button disabled")
	screen._apply_online_gates(true)
	assert_false(screen._chat_send_button.disabled, "online re-enables the send button")


func test_social_chat_has_no_polling() -> void:
	var screen := _mount(SocialScreen.new())
	assert_false(screen.has_method("_on_chat_poll_timeout"), "poll timeout handler retired (TDD §3.24)")
	assert_false(screen.has_method("_update_chat_polling"), "poll update hook retired")


# --- Presence (TDD §3.25) -----------------------------------------------------------

func test_social_friend_row_shows_online_presence() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle_layout(2)
	var ada_code := IdentityService.derive_player_code("mock:Ada")
	(SocialManager._backend as MockSocialBackend).set_friend_presence(ada_code, true)
	assert_eq(_friend_level_text(screen, "Ada"), "%s · %s" % [tr("profile_level") % [7], tr("social_presence_online")], "online friend gets the presence suffix")


func test_social_friend_row_shows_relative_last_seen() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle_layout(2)
	var ada_code := IdentityService.derive_player_code("mock:Ada")
	var two_hours_ago := int(Time.get_unix_time_from_system()) - 7200
	(SocialManager._backend as MockSocialBackend).set_friend_presence(ada_code, false, two_hours_ago)
	assert_eq(_friend_level_text(screen, "Ada"), "%s · %s" % [tr("profile_level") % [7], tr("social_seen_hours") % [2]], "offline friend shows relative last-seen")


func test_social_friend_row_plain_without_presence_data() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle_layout(2)
	assert_eq(_friend_level_text(screen, "Ada"), tr("profile_level") % [7], "no presence data keeps the plain level line")


func test_social_friend_row_gated_when_offline() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle_layout(2)
	var ada_code := IdentityService.derive_player_code("mock:Ada")
	(SocialManager._backend as MockSocialBackend).set_friend_presence(ada_code, true)
	assert_eq(_friend_level_text(screen, "Ada"), "%s · %s" % [tr("profile_level") % [7], tr("social_presence_online")], "presence visible while online")
	OnlineService.force_offline(true)
	screen._on_presence_changed({})
	assert_eq(_friend_level_text(screen, "Ada"), tr("profile_level") % [7], "offline-gated rows fall back to the plain line")
	OnlineService.force_offline(false)


func test_social_member_row_shows_online_presence() -> void:
	var screen := _mount(SocialScreen.new())
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	screen._on_join_pressed(teams[0])
	screen._tabs.current_tab = 1
	screen._select_subtab(1)
	await _settle_layout(2)
	# The mock team's members are ["Ada", "You"]; Ada is the leader and her
	# code matches her friend code (deterministic mock derivation).
	var ada_code := IdentityService.derive_player_code("mock:Ada")
	(SocialManager._backend as MockSocialBackend).set_friend_presence(ada_code, true)
	assert_eq(_member_role_text(screen, "Ada"), "%s · %s" % [tr("team_leader"), tr("social_presence_online")], "leader row gets the presence suffix")


# --- Layout ---------------------------------------------------------------------
## Regression: main pages live in a TabContainer, which only lays out the
## CURRENT tab (hidden subtrees are not sorted), so each page is measured on
## its own turn. The page fills the container's CONTENT rect — the panel
## stylebox's content margins (the art frame insets) shrink that rect by
## design, so expectations are computed from the live stylebox rather than
## hardcoded. Team sub-pages still live in a plain (non-container) host, where
## an unpinned page collapses to its minimum size at top-left (see the GOTCHA
## documented in base_screen.gd).

func test_profile_pages_fill_their_host() -> void:
	var screen := _mount(ProfileScreen.new())
	await _settle_layout()
	assert_gt(_host.size.y, 1000.0, "test host is phone-sized")
	for i in screen._pages.size():
		screen._tabs.current_tab = i
		await _settle_layout(2)
		var page: Control = screen._pages[i]
		var insets := _tab_content_insets(screen._tabs)
		assert_almost_eq(page.size.x, screen._tabs.size.x - insets.x, 2.0, "profile page %d spans the tab content width" % i)
		assert_almost_eq(page.position.y + page.size.y, screen._tabs.size.y - insets.y, 2.0, "profile page %d reaches the tab content bottom" % i)


func test_social_pages_fill_their_host() -> void:
	var screen := _mount(SocialScreen.new())
	await _settle_layout()
	for i in screen._pages.size():
		screen._tabs.current_tab = i
		await _settle_layout(2)
		var page: Control = screen._pages[i]
		var insets := _tab_content_insets(screen._tabs)
		assert_almost_eq(page.size.x, screen._tabs.size.x - insets.x, 2.0, "social page %d spans the tab content width" % i)
		assert_almost_eq(page.position.y + page.size.y, screen._tabs.size.y - insets.y, 2.0, "social page %d reaches the tab content bottom" % i)


func test_social_team_subpages_fill_their_host() -> void:
	var screen := _mount(SocialScreen.new())
	# Sub-pages sit inside the (hidden-by-default) team content; containers do
	# not sort hidden subtrees, so join a team and open the tab first.
	var teams: Array[Dictionary] = await SocialManager.search_teams("")
	screen._on_join_pressed(teams[0])
	screen._tabs.current_tab = 1
	await _settle_layout()
	assert_true(screen._team_content.visible, "team content visible after joining")
	for i in screen._subpages.size():
		var subpage: Control = screen._subpages[i]
		assert_almost_eq(subpage.size.x, subpage.get_parent().size.x, 2.0, "team subpage %d spans the host width" % i)
		assert_almost_eq(subpage.size.y, subpage.get_parent().size.y, 2.0, "team subpage %d fills the host height" % i)


func test_social_search_bar_stretches_full_width() -> void:
	var screen := _mount(SocialScreen.new())
	screen._tabs.current_tab = 2
	await _settle_layout()
	var bar := screen._search_edit.get_parent() as HBoxContainer
	assert_not_null(bar, "search edit lives in a bar row")
	assert_almost_eq(bar.size.x, screen._pages[2].size.x, 2.0, "bar row spans the search page")
	assert_gt(screen._search_edit.size.x, bar.size.x - screen._search_mode.size.x - 16.0, "search edit takes the remaining width")


# --- Helpers --------------------------------------------------------------------

## The panel stylebox content margins that shrink the TabContainer's page area
## (art frame insets — left/right/bottom; the top is the tab strip).
## NOTE: StyleBoxTexture.get_content_margin() returns -1 (margins are
## size-dependent and the _for_size variant is not exposed to GDScript in
## 4.7); at this project's phone-sized host the content insets equal the
## texture's natural 9-slice cuts, so those are what we assert against.
func _tab_content_insets(tabs: TabContainer) -> Vector2:
	var sb := tabs.get_theme_stylebox("panel")
	if sb == null:
		return Vector2.ZERO
	if sb is StyleBoxTexture and (sb as StyleBoxTexture).texture != null:
		var st := sb as StyleBoxTexture
		return Vector2(
			st.get_texture_margin(SIDE_LEFT) + st.get_texture_margin(SIDE_RIGHT),
			st.get_texture_margin(SIDE_BOTTOM)
		)
	if sb is StyleBoxFlat:
		var sf := sb as StyleBoxFlat
		return Vector2(sf.content_margin_left + sf.content_margin_right, sf.content_margin_bottom)
	return Vector2.ZERO


func _settle_layout(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame


func _mount(screen: BaseScreen) -> BaseScreen:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


func _make_click(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = true
	return event


## The level line of a friend row by display name — presence text rides this
## label (TDD §3.25). Row shape: Panel > HBox > [Portrait, VBox(name, level)].
func _friend_level_text(screen: SocialScreen, friend_name: String) -> String:
	for row in screen._friends_list.get_children():
		var panel := row as PanelContainer
		if panel == null:
			continue
		var hbox := panel.get_child(0) as HBoxContainer
		if hbox == null or hbox.get_child_count() < 2:
			continue
		var info := hbox.get_child(1) as VBoxContainer
		if info == null or info.get_child_count() < 2:
			continue
		if str((info.get_child(0) as Label).text) == friend_name:
			return str((info.get_child(1) as Label).text)
	return "<row not found>"


## The role line of a member row by display name (same row shape as friends).
func _member_role_text(screen: SocialScreen, member_name: String) -> String:
	for row in screen._members_list.get_children():
		var panel := row as PanelContainer
		if panel == null:
			continue
		var hbox := panel.get_child(0) as HBoxContainer
		if hbox == null or hbox.get_child_count() < 2:
			continue
		var info := hbox.get_child(1) as VBoxContainer
		if info == null or info.get_child_count() < 2:
			continue
		if str((info.get_child(0) as Label).text) == member_name:
			return str((info.get_child(1) as Label).text)
	return "<row not found>"


## Marks a slot-qualified cosmetic ("slot:id") as purchased so owned/locked
## gating (TDD §3.20) does not intercept the pick under test.
func _seed_owned(qualified_id: String) -> void:
	var domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	var owned: Array = domain.get("owned_cosmetics", [])
	owned.append(qualified_id)
	domain["owned_cosmetics"] = owned
	SaveSystem.set_domain(ShopLogic.SHOP_DOMAIN, domain)

