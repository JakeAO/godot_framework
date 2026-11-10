class_name SocialScreen
extends BaseScreen
## Social screen with tabbed pages (TDD §3.16, D5a v2 surface):
##   - Friends: add-by-code field, pending invitations (received -> accept /
##     reject, sent -> cancel), friends list with block/remove actions and a
##     dimmed blocked-users section with unblock.
##   - Team: when off-team, a find-a-team CTA + create-team entry + a "request
##     sent" state; when on-team, a header (LUT banner, name, access mode,
##     leader-only settings) plus Chat / Members sub-tabs.
##   - Search: search bar + friend/team toggle; team rows show the LUT banner
##     and access mode and route to join (open teams) or request-join
##     (by-request teams).
## All social data flows through SocialManager — screens never touch backends
## directly. Team banners render via TeamBannerView (TDD §3.19); legacy saves
## with a flat `banner_color` fall back to a colored chip. The Chat subtab is
## realtime (TDD §3.24): messages arrive via the social_chat_message signal and
## the send box below the list posts through SocialManager.send_chat().

const FEED_FLAG: String = "social_feed_enabled"
const TEAM_DOMAIN: String = "team"
const ACCESS_OPEN: String = "open"
const ACCESS_BY_REQUEST: String = "by-request"
const MAX_TEAM_NAME_LENGTH: int = 24
const HEADER_BANNER_SIZE: Vector2 = Vector2(48, 96)
const ROW_BANNER_SIZE: Vector2 = Vector2(32, 64)
const BANNER_DIALOG_SIZE: Vector2 = Vector2(620, 780)
const TAB_KEYS: Array[String] = ["social_tab_friends", "social_tab_team", "social_tab_search"]
const SUBTAB_KEYS: Array[String] = ["social_subtab_chat", "social_subtab_members"]
const SEARCH_MODE_KEYS: Array[String] = ["social_tab_friends", "social_tab_team"]
const FRIEND_PORTRAIT_SIZE: float = 48.0

var _tabs: TabContainer = null
var _pages: Array[Control] = []
var _friends_list: VBoxContainer = null
var _friends_empty: Label = null
var _add_friend_edit: LineEdit = null
var _add_friend_button: Button = null
var _add_friend_error: Label = null
var _invitations_section: VBoxContainer = null
var _invitations_label: Label = null
var _invitations_list: VBoxContainer = null
var _blocked_section: VBoxContainer = null
var _blocked_label: Label = null
var _blocked_list: VBoxContainer = null
var _no_team_box: VBoxContainer = null
var _no_team_label: Label = null
var _find_team_button: Button = null
var _create_team_button: Button = null
var _request_sent_label: Label = null
var _team_content: VBoxContainer = null
var _team_banner_view: TeamBannerView = null
var _team_name_label: Label = null
var _access_label: Label = null
var _settings_button: Button = null
var _members_count_label: Label = null
var _power_label: Label = null
var _subtab_buttons: Array[Button] = []
var _subpages: Array[Control] = []
var _chat_list: VBoxContainer = null
var _members_list: VBoxContainer = null
var _search_edit: LineEdit = null
var _search_mode: OptionButton = null
var _results_list: VBoxContainer = null
var _no_results_label: Label = null
var _chat_input: LineEdit = null
var _chat_send_button: Button = null
var _offline_banner: Label = null


func _ready() -> void:
	# Connect BEFORE super._ready(): it runs _apply_locale(), whose first
	# refreshes emit the changed signals — connecting after would drop the
	# initial render (empty friends/invitations on first open).
	if not EventBus.social_friends_changed.is_connected(_on_friends_changed):
		EventBus.social_friends_changed.connect(_on_friends_changed)
	if not EventBus.social_invitations_changed.is_connected(_on_invitations_changed):
		EventBus.social_invitations_changed.connect(_on_invitations_changed)
	if not EventBus.social_team_changed.is_connected(_on_team_changed):
		EventBus.social_team_changed.connect(_on_team_changed)
	if not EventBus.social_chat_message.is_connected(_on_chat_message):
		EventBus.social_chat_message.connect(_on_chat_message)
	if not EventBus.social_presence_changed.is_connected(_on_presence_changed):
		EventBus.social_presence_changed.connect(_on_presence_changed)
	if not EventBus.backend_state_changed.is_connected(_on_backend_state_changed):
		EventBus.backend_state_changed.connect(_on_backend_state_changed)
	super._ready()
	_apply_online_gates(OnlineService.is_online())


func _exit_tree() -> void:
	if EventBus.social_friends_changed.is_connected(_on_friends_changed):
		EventBus.social_friends_changed.disconnect(_on_friends_changed)
	if EventBus.social_invitations_changed.is_connected(_on_invitations_changed):
		EventBus.social_invitations_changed.disconnect(_on_invitations_changed)
	if EventBus.social_team_changed.is_connected(_on_team_changed):
		EventBus.social_team_changed.disconnect(_on_team_changed)
	if EventBus.social_chat_message.is_connected(_on_chat_message):
		EventBus.social_chat_message.disconnect(_on_chat_message)
	if EventBus.social_presence_changed.is_connected(_on_presence_changed):
		EventBus.social_presence_changed.disconnect(_on_presence_changed)
	if EventBus.backend_state_changed.is_connected(_on_backend_state_changed):
		EventBus.backend_state_changed.disconnect(_on_backend_state_changed)
	super._exit_tree()


func _apply_locale() -> void:
	for i in _tabs.get_tab_count():
		_tabs.set_tab_title(i, tr(TAB_KEYS[i]))
	for i in _subtab_buttons.size():
		_subtab_buttons[i].text = tr(SUBTAB_KEYS[i])
	for i in SEARCH_MODE_KEYS.size():
		_search_mode.set_item_text(i, tr(SEARCH_MODE_KEYS[i]))
	_no_team_label.text = tr("social_no_team")
	_find_team_button.text = tr("social_find_team")
	UIManager.attach_tooltip(_find_team_button, tr("tooltip_team_join"))
	_create_team_button.text = tr("team_create")
	_request_sent_label.text = tr("team_request_sent")
	_add_friend_edit.placeholder_text = tr("social_add_friend_hint")
	_add_friend_button.text = tr("social_add_friend")
	_search_edit.placeholder_text = tr("social_search_hint")
	_chat_input.placeholder_text = tr("social_chat_hint")
	_chat_send_button.text = tr("social_chat_send")
	_no_results_label.text = tr("social_no_results")
	_invitations_label.text = tr("social_invitations")
	_blocked_label.text = tr("social_blocked")
	_settings_button.text = tr("team_settings")
	_refresh_friends()
	_refresh_invitations()
	_refresh_blocked()
	_refresh_team()
	_refresh_results()
	_apply_online_gates(OnlineService.is_online())


# --- UI -----------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	# Pin to full rect: an unanchored container shrinks to minimum size at top-left.
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Offline hint (TDD §3.18): always in the tree with a reserved line so the
	# layout never jumps on connectivity transitions; only the text toggles.
	_offline_banner = Label.new()
	_offline_banner.theme_type_variation = &"LabelDim"
	_offline_banner.custom_minimum_size.y = 20.0
	vbox.add_child(_offline_banner)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_main_tab_changed)
	vbox.add_child(_tabs)

	_pages.append(_build_friends_page())
	_pages.append(_build_team_page())
	_pages.append(_build_search_page())
	for i in _pages.size():
		var page: Control = _pages[i]
		page.name = TAB_KEYS[i]
		_tabs.add_child(page)

	_select_subtab(0)


func _build_tab_bar(keys: Array[String], buttons: Array[Button], on_pressed: Callable) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	for key in keys:
		var button := Button.new()
		button.theme_type_variation = "ButtonNav"
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(on_pressed.bind(button))
		bar.add_child(button)
		buttons.append(button)
	return bar


func _build_friends_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	page.add_child(_build_add_friend_row())

	_add_friend_error = Label.new()
	_add_friend_error.theme_type_variation = &"LabelDim"
	_add_friend_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Bound the wrap width: an autowrapped label with ~0 min width wraps one
	# character per line during min-size computation and inflates the page.
	_add_friend_error.custom_minimum_size.x = 260.0
	_add_friend_error.visible = false
	page.add_child(_add_friend_error)

	_invitations_section = VBoxContainer.new()
	_invitations_section.add_theme_constant_override("separation", 4)
	_invitations_section.visible = false
	_invitations_label = Label.new()
	_invitations_label.text = tr("social_invitations")
	_invitations_label.theme_type_variation = &"LabelDim"
	_invitations_section.add_child(_invitations_label)
	_invitations_list = VBoxContainer.new()
	_invitations_list.add_theme_constant_override("separation", 4)
	_invitations_section.add_child(_invitations_list)
	page.add_child(_invitations_section)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)

	var list_box := VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 8)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)

	_friends_list = VBoxContainer.new()
	_friends_list.add_theme_constant_override("separation", 8)
	_friends_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.add_child(_friends_list)

	_friends_empty = Label.new()
	_friends_empty.text = tr("social_no_friends")
	_friends_empty.theme_type_variation = &"LabelDim"
	_friends_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_friends_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_friends_empty.visible = false
	list_box.add_child(_friends_empty)

	_blocked_section = VBoxContainer.new()
	_blocked_section.add_theme_constant_override("separation", 4)
	_blocked_section.visible = false
	_blocked_label = Label.new()
	_blocked_label.text = tr("social_blocked")
	_blocked_label.theme_type_variation = &"LabelDim"
	_blocked_section.add_child(_blocked_label)
	_blocked_list = VBoxContainer.new()
	_blocked_list.add_theme_constant_override("separation", 4)
	_blocked_section.add_child(_blocked_list)
	list_box.add_child(_blocked_section)

	return page


func _build_add_friend_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_add_friend_edit = LineEdit.new()
	_add_friend_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_friend_edit.placeholder_text = tr("social_add_friend_hint")
	_add_friend_edit.text_submitted.connect(_on_add_friend_pressed)
	row.add_child(_add_friend_edit)
	_add_friend_button = Button.new()
	_add_friend_button.theme_type_variation = "ButtonAccent"
	_add_friend_button.text = tr("social_add_friend")
	_add_friend_button.pressed.connect(_on_add_friend_pressed)
	row.add_child(_add_friend_button)
	return row


func _build_team_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	# Not-on-team CTA block.
	_no_team_box = VBoxContainer.new()
	_no_team_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_no_team_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_no_team_box.add_theme_constant_override("separation", 8)
	_no_team_label = Label.new()
	_no_team_label.text = tr("social_no_team")
	_no_team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_team_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Bound the wrap width: an autowrapped label with ~0 min width wraps one
	# character per line during min-size computation and inflates the page.
	_no_team_label.custom_minimum_size.x = 260.0
	_no_team_box.add_child(_no_team_label)
	_find_team_button = Button.new()
	_find_team_button.text = tr("social_find_team")
	_find_team_button.pressed.connect(_on_find_team_pressed)
	_no_team_box.add_child(_find_team_button)
	_create_team_button = Button.new()
	_create_team_button.theme_type_variation = "ButtonAccent"
	_create_team_button.custom_minimum_size.x = 300.0
	_create_team_button.text = tr("team_create")
	_create_team_button.pressed.connect(_open_create_dialog)
	_no_team_box.add_child(_create_team_button)
	_request_sent_label = Label.new()
	_request_sent_label.text = tr("team_request_sent")
	_request_sent_label.theme_type_variation = &"LabelDim"
	_request_sent_label.visible = false
	_no_team_box.add_child(_request_sent_label)
	page.add_child(_no_team_box)

	# On-team content: header banner + stats, then Chat/Members sub-tabs.
	# EXPAND_FILL is what makes the sub-pages host (and thus the chat list)
	# fill the page once the off-team CTA box hides — without it the VBox
	# packs children at minimum size and the sub-pages collapse to 0 height.
	_team_content = VBoxContainer.new()
	_team_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_team_content.add_theme_constant_override("separation", 8)
	_team_content.visible = false
	page.add_child(_team_content)

	var header := PanelContainer.new()
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	header.add_child(header_row)
	_team_banner_view = TeamBannerView.new()
	_team_banner_view.custom_minimum_size = HEADER_BANNER_SIZE
	_team_banner_view.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(_team_banner_view)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_team_name_label = Label.new()
	_team_name_label.add_theme_font_size_override("font_size", 22)
	title_box.add_child(_team_name_label)
	_access_label = Label.new()
	_access_label.theme_type_variation = &"LabelDim"
	title_box.add_child(_access_label)
	header_row.add_child(title_box)
	_settings_button = Button.new()
	_settings_button.theme_type_variation = "ButtonNav"
	_settings_button.text = tr("team_settings")
	_settings_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_settings_button.pressed.connect(_open_settings_dialog)
	header_row.add_child(_settings_button)
	_team_content.add_child(header)

	var stats_row := HBoxContainer.new()
	_members_count_label = Label.new()
	_members_count_label.theme_type_variation = &"LabelDim"
	stats_row.add_child(_members_count_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.add_child(spacer)
	_power_label = Label.new()
	_power_label.theme_type_variation = &"LabelGold"
	stats_row.add_child(_power_label)
	_team_content.add_child(stats_row)

	_team_content.add_child(_build_tab_bar(SUBTAB_KEYS, _subtab_buttons, _on_subtab_pressed))

	var subpages_host := Control.new()
	subpages_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_team_content.add_child(subpages_host)

	_subpages.append(_build_chat_subpage())
	_subpages.append(_build_scroll_page(_make_members_list()))
	for subpage in _subpages:
		subpage.set_anchors_preset(Control.PRESET_FULL_RECT)
		subpages_host.add_child(subpage)

	return page


func _build_scroll_page(list: VBoxContainer) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	return scroll


## Chat subtab (TDD §3.24): scrollable history + a send box pinned below it.
## The list itself stays inside the scroll so long conversations push up while
## the input row remains reachable.
func _build_chat_subpage() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)
	_chat_list = VBoxContainer.new()
	_chat_list.add_theme_constant_override("separation", 8)
	_chat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_chat_list)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 8)
	_chat_input = LineEdit.new()
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.placeholder_text = tr("social_chat_hint")
	_chat_input.text_submitted.connect(_on_chat_submitted)
	input_row.add_child(_chat_input)
	_chat_send_button = Button.new()
	_chat_send_button.theme_type_variation = "ButtonNav"
	_chat_send_button.text = tr("social_chat_send")
	_chat_send_button.pressed.connect(_on_chat_send_pressed)
	input_row.add_child(_chat_send_button)
	page.add_child(input_row)

	return page


func _make_members_list() -> VBoxContainer:
	_members_list = VBoxContainer.new()
	_members_list.add_theme_constant_override("separation", 8)
	return _members_list


func _build_search_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var bar_row := HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 8)
	_search_edit = LineEdit.new()
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.placeholder_text = tr("social_search_hint")
	_search_edit.text_changed.connect(_refresh_results)
	bar_row.add_child(_search_edit)

	_search_mode = OptionButton.new()
	for key in SEARCH_MODE_KEYS:
		_search_mode.add_item(tr(key))
	_search_mode.item_selected.connect(_refresh_results)
	bar_row.add_child(_search_mode)
	page.add_child(bar_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)

	_results_list = VBoxContainer.new()
	_results_list.add_theme_constant_override("separation", 8)
	_results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_results_list)

	_no_results_label = Label.new()
	_no_results_label.text = tr("social_no_results")
	_no_results_label.theme_type_variation = &"LabelDim"
	_no_results_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_results_label.visible = false
	scroll.add_child(_no_results_label)

	return page


# --- Tab switching --------------------------------------------------------------

func _select_tab(index: int) -> void:
	if index < 0 or index >= _tabs.get_tab_count():
		return
	_tabs.current_tab = index


func _select_subtab(index: int) -> void:
	if index < 0 or index >= _subtab_buttons.size():
		return
	for i in _subtab_buttons.size():
		_subtab_buttons[i].button_pressed = (i == index)
	for i in _subpages.size():
		_subpages[i].visible = (i == index)
	if index == 1 and bool(SaveSystem.get_domain(TEAM_DOMAIN).get("on_team", false)):
		_render_members(SaveSystem.get_domain(TEAM_DOMAIN))
	_refresh_chat_if_visible()


func _on_main_tab_changed(index: int) -> void:
	if index == 0:
		# Rows were built on the last friends fetch; rebuild from the local
		# cache so presence text is fresh (no network).
		_render_friends(SocialManager.get_friends_cache())
	elif index == 1:
		_refresh_chat_if_visible()


## Presence deltas re-render the VISIBLE friend/member rows in place (TDD
## §3.25); hidden lists pick up fresh text on their next natural rebuild.
func _on_presence_changed(_presences: Dictionary) -> void:
	if not is_inside_tree():
		return
	if _tabs.current_tab == 0:
		_render_friends(SocialManager.get_friends_cache())
	elif _tabs.current_tab == 1 and _subpages.size() > 1 and _subpages[1].visible \
			and bool(SaveSystem.get_domain(TEAM_DOMAIN).get("on_team", false)):
		_render_members(SaveSystem.get_domain(TEAM_DOMAIN))


# --- Refresh --------------------------------------------------------------------

## Triggers a fetch; the social_friends_changed signal renders the rows.
func _refresh_friends() -> void:
	await SocialManager.fetch_friends()


func _on_friends_changed(friends: Array[Dictionary]) -> void:
	_render_friends(friends)


func _render_friends(friends: Array[Dictionary]) -> void:
	if not is_inside_tree():
		return
	for child in _friends_list.get_children():
		_friends_list.remove_child(child)
		child.queue_free()

	var feed_enabled := RemoteConfig.is_enabled(FEED_FLAG, true)
	_friends_empty.visible = not feed_enabled
	if not feed_enabled:
		return
	for friend in friends:
		_friends_list.add_child(_build_friend_row(friend))


## Triggers a fetch; the social_invitations_changed signal renders the rows.
func _refresh_invitations() -> void:
	await SocialManager.fetch_invitations()


func _on_invitations_changed(invitations: Array[Dictionary]) -> void:
	if not is_inside_tree():
		return
	for child in _invitations_list.get_children():
		_invitations_list.remove_child(child)
		child.queue_free()
	_invitations_section.visible = invitations.size() > 0
	for invitation in invitations:
		_invitations_list.add_child(_build_invitation_row(invitation))


func _refresh_blocked() -> void:
	var blocked: Array[Dictionary] = await SocialManager.fetch_blocked()
	if not is_inside_tree():
		return
	for child in _blocked_list.get_children():
		_blocked_list.remove_child(child)
		child.queue_free()
	_blocked_section.visible = blocked.size() > 0
	for entry in blocked:
		_blocked_list.add_child(_build_blocked_row(entry))


func _refresh_team() -> void:
	var team: Dictionary = SaveSystem.get_domain(TEAM_DOMAIN)
	var on_team := bool(team.get("on_team", false))
	_no_team_box.visible = not on_team
	_request_sent_label.visible = not on_team and not str(SaveSystem.get_value(TEAM_DOMAIN, "requested_team_id", "")).is_empty()
	_team_content.visible = on_team
	if on_team:
		_team_name_label.text = str(team.get("team_name", ""))
		_access_label.text = tr(_access_key(str(team.get("access_mode", ACCESS_OPEN))))
		# Legacy saves carry a flat banner_color instead of a recipe; the view
		# then renders a fallback chip in that color.
		_team_banner_view.setup(_recipe_from_domain(team), _legacy_banner_color(str(team.get("banner_color", ""))))
		_settings_button.visible = str(team.get("leader_code", "")) == IdentityService.get_player_code()
		var members: Array = team.get("members", [])
		_members_count_label.text = tr("team_member_count") % [members.size()]
		_power_label.text = tr("team_power") % [int(team.get("power", 0))]
		_render_members(team)
	_refresh_chat_if_visible()


## Rebuilds the member rows (name + role line, presence suffix per TDD §3.25).
## `member_codes` is parallel to `members` — legacy saves without it simply get
## plain role lines.
func _render_members(team: Dictionary) -> void:
	if not is_inside_tree():
		return
	for child in _members_list.get_children():
		_members_list.remove_child(child)
		child.queue_free()
	var leader_name := str(team.get("leader_name", ""))
	var members: Array = team.get("members", [])
	var member_codes: Array = team.get("member_codes", [])
	for i in members.size():
		var code := str(member_codes[i]) if i < member_codes.size() else ""
		_members_list.add_child(_build_member_row(str(members[i]), not leader_name.is_empty() and str(members[i]) == leader_name, code))


func _refresh_results() -> void:
	for child in _results_list.get_children():
		_results_list.remove_child(child)
		child.queue_free()

	var query := str(_search_edit.text).to_lower().strip_edges()
	var show_teams := _search_mode.selected == 1
	var count := 0
	if show_teams:
		var teams: Array[Dictionary] = await SocialManager.search_teams(query)
		for team in teams:
			_results_list.add_child(_build_team_row(team))
			count += 1
	else:
		var friends: Array[Dictionary] = await SocialManager.fetch_friends()
		for friend in friends:
			var entry_name := str(friend.get("name", "")).to_lower()
			if query != "" and not entry_name.contains(query):
				continue
			_results_list.add_child(_build_friend_row(friend))
			count += 1
	if not is_inside_tree():
		return
	_no_results_label.visible = count == 0


# --- Chat (realtime per TDD §3.24 — v1 polling retired) -----------------------------

func _is_chat_visible() -> bool:
	var on_team := bool(SaveSystem.get_domain(TEAM_DOMAIN).get("on_team", false))
	# Refreshes pause while the backend is unverified (TDD §3.18); the last
	# known messages stay visible, just not re-fetched.
	return on_team and OnlineService.is_online() and _subpages[0].visible and _tabs.current_tab == 1


## One-shot catch-up rebuild whenever the chat subtab becomes visible (main tab
## or subtab switch, team change, connectivity flip). Ongoing delivery is push:
## the manager's socket feed arrives via social_chat_message.
func _refresh_chat_if_visible() -> void:
	if _is_chat_visible():
		_rebuild_chat()


## Posts through SocialManager; on success the field clears and the row lands
## via the social_chat_message echo (the server pushes it to the sender too).
func _submit_chat() -> void:
	var text := str(_chat_input.text).strip_edges()
	if text.is_empty():
		return
	var result: Dictionary = await SocialManager.send_chat(text)
	if bool(result.get("ok", false)):
		_chat_input.clear()


func _on_chat_submitted(_text: String) -> void:
	_submit_chat()


func _on_chat_send_pressed() -> void:
	_submit_chat()


func _rebuild_chat() -> void:
	if not is_inside_tree():
		return
	var messages: Array[Dictionary] = await SocialManager.fetch_chat(SocialManager.DEFAULT_CHAT_LIMIT)
	if not is_inside_tree():
		return
	for child in _chat_list.get_children():
		_chat_list.remove_child(child)
		child.queue_free()
	for message in messages:
		_chat_list.add_child(_make_chat_row(message))


func _on_chat_message(message: Dictionary) -> void:
	if not _is_chat_visible():
		return
	_chat_list.add_child(_make_chat_row(message))


func _make_chat_row(message: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var sender := Label.new()
	sender.theme_type_variation = &"LabelGold"
	sender.text = str(message.get("sender_name", "")) + ":"
	row.add_child(sender)
	var text := Label.new()
	text.text = str(message.get("text", ""))
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(text)
	return row


# --- Row builders -----------------------------------------------------------------

func _build_friend_row(friend: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var portrait := PortraitView.new()
	portrait.setup(FRIEND_PORTRAIT_SIZE)
	portrait.apply_profile(friend)
	portrait.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(portrait)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(info)

	var name_label := Label.new()
	name_label.text = str(friend.get("name", ""))
	info.add_child(name_label)

	# Presence rides the existing level line (TDD §3.25): "Level 7" becomes
	# "Level 7 · online" / "Level 7 · seen 2h ago"; same Label, different text.
	var level_label := Label.new()
	level_label.theme_type_variation = &"LabelDim"
	level_label.text = _presence_line(
		tr("profile_level") % [int(friend.get("level", 0))],
		str(friend.get("player_code", "")),
		int(friend.get("last_seen", 0)))
	info.add_child(level_label)

	var score_label := Label.new()
	score_label.theme_type_variation = &"LabelGold"
	score_label.text = str(int(friend.get("best_score", 0)))
	hbox.add_child(score_label)

	var block_button := Button.new()
	block_button.theme_type_variation = "ButtonNav"
	block_button.text = tr("social_block")
	block_button.disabled = _actions_gated()
	block_button.pressed.connect(_on_block_pressed.bind(str(friend.get("player_code", ""))))
	hbox.add_child(block_button)

	var remove_button := Button.new()
	remove_button.theme_type_variation = "ButtonNav"
	remove_button.text = tr("social_remove")
	remove_button.disabled = _actions_gated()
	remove_button.pressed.connect(_on_remove_friend_pressed.bind(str(friend.get("player_code", ""))))
	hbox.add_child(remove_button)

	return panel


func _build_invitation_row(invitation: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	panel.add_child(hbox)

	var name_label := Label.new()
	name_label.text = str(invitation.get("name", ""))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(name_label)

	var code := str(invitation.get("player_code", ""))
	if str(invitation.get("direction", "")) == "received":
		var accept_button := Button.new()
		accept_button.theme_type_variation = "ButtonAccent"
		accept_button.text = tr("social_accept")
		accept_button.disabled = _actions_gated()
		accept_button.pressed.connect(_on_respond_invitation_pressed.bind(code, true))
		hbox.add_child(accept_button)
		var reject_button := Button.new()
		reject_button.theme_type_variation = "ButtonNav"
		reject_button.text = tr("social_reject")
		reject_button.disabled = _actions_gated()
		reject_button.pressed.connect(_on_respond_invitation_pressed.bind(code, false))
		hbox.add_child(reject_button)
	else:
		var cancel_button := Button.new()
		cancel_button.theme_type_variation = "ButtonNav"
		cancel_button.text = tr("social_cancel")
		cancel_button.disabled = _actions_gated()
		cancel_button.pressed.connect(_on_respond_invitation_pressed.bind(code, false))
		hbox.add_child(cancel_button)

	return panel


func _build_blocked_row(entry: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	panel.add_child(hbox)

	var name_label := Label.new()
	name_label.theme_type_variation = &"LabelDim"
	name_label.text = str(entry.get("name", ""))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(name_label)

	var unblock_button := Button.new()
	unblock_button.theme_type_variation = "ButtonNav"
	unblock_button.text = tr("social_unblock")
	unblock_button.disabled = _actions_gated()
	unblock_button.pressed.connect(_on_unblock_pressed.bind(str(entry.get("player_code", ""))))
	hbox.add_child(unblock_button)

	return panel


func _build_member_row(member_name: String, is_leader: bool, member_code: String = "") -> PanelContainer:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var portrait := PortraitView.new()
	portrait.setup(FRIEND_PORTRAIT_SIZE)
	var icon_index := absi(member_name.hash()) % PortraitCatalog.ICONS.size()
	var sample: Dictionary = {"name": member_name, "portrait_icon": PortraitCatalog.ICONS[icon_index]["id"]}
	portrait.apply_profile(sample)
	portrait.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(portrait)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(info)

	var name_label := Label.new()
	name_label.text = member_name
	info.add_child(name_label)

	# Presence rides the role line (TDD §3.25): "Leader" becomes
	# "Leader · online" / "Member · seen 2h ago".
	var role_label := Label.new()
	role_label.theme_type_variation = &"LabelDim"
	role_label.text = _presence_line(tr("team_leader") if is_leader else tr("team_member"), member_code)
	info.add_child(role_label)

	return panel


func _build_team_row(team: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var banner := TeamBannerView.new()
	banner.custom_minimum_size = ROW_BANNER_SIZE
	banner.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	banner.setup(_recipe_from_row(team), ThemeFactory.COLOR_PANEL)
	hbox.add_child(banner)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(info)

	var name_label := Label.new()
	name_label.text = str(team.get("name", ""))
	info.add_child(name_label)

	var meta_label := Label.new()
	meta_label.theme_type_variation = &"LabelDim"
	meta_label.text = "%s · %s" % [tr("team_power") % [int(team.get("power", 0))], tr(_access_key(str(team.get("access_mode", ACCESS_OPEN))))]
	info.add_child(meta_label)

	var team_id := str(team.get("team_id", ""))
	var button := Button.new()
	if str(team.get("access_mode", ACCESS_OPEN)) == ACCESS_BY_REQUEST:
		button.theme_type_variation = "ButtonNav"
		var requested := not team_id.is_empty() and str(SaveSystem.get_value(TEAM_DOMAIN, "requested_team_id", "")) == team_id
		if requested:
			button.text = tr("team_request_sent")
			button.disabled = true
		else:
			button.text = tr("social_request")
			button.pressed.connect(_on_request_join_pressed.bind(team_id))
	else:
		button.theme_type_variation = "ButtonAccent"
		button.text = tr("social_join")
		button.pressed.connect(_on_join_pressed.bind(team))
	if _actions_gated():
		button.disabled = true
	hbox.add_child(button)

	return panel


# --- Team dialogs -----------------------------------------------------------------

func _open_create_dialog() -> void:
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.text = tr("team_name_label")
	name_row.add_child(name_label)
	var name_edit := LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.max_length = MAX_TEAM_NAME_LENGTH
	name_edit.placeholder_text = tr("team_name_placeholder")
	name_row.add_child(name_edit)
	content.add_child(name_row)

	var access_row := _build_access_row(0)
	content.add_child(access_row)

	var editor := TeamBannerEditor.new()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(editor)

	var access_option := access_row.get_child(1) as OptionButton
	content.add_child(_build_dialog_button_row(tr("team_create"), _on_create_team_pressed.bind(name_edit, access_option, editor)))
	UIManager.show_dialog(content, tr("team_create"), true, BANNER_DIALOG_SIZE, false)


func _open_settings_dialog() -> void:
	var team := SaveSystem.get_domain(TEAM_DOMAIN)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.text = tr("team_name_label")
	name_row.add_child(name_label)
	var name_edit := LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.max_length = MAX_TEAM_NAME_LENGTH
	name_edit.placeholder_text = tr("team_name_placeholder")
	name_edit.text = str(team.get("team_name", ""))
	name_row.add_child(name_edit)
	content.add_child(name_row)

	var access_row := _build_access_row(1 if str(team.get("access_mode", ACCESS_OPEN)) == ACCESS_BY_REQUEST else 0)
	content.add_child(access_row)

	var editor := TeamBannerEditor.new()
	editor.setup(_recipe_from_domain(team))
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(editor)

	var requests_label := Label.new()
	requests_label.text = tr("team_requests")
	requests_label.theme_type_variation = &"LabelDim"
	content.add_child(requests_label)
	var requests_box := VBoxContainer.new()
	requests_box.add_theme_constant_override("separation", 4)
	content.add_child(requests_box)

	var access_option := access_row.get_child(1) as OptionButton
	content.add_child(_build_dialog_button_row(tr("social_save"), _on_save_team_settings_pressed.bind(name_edit, access_option, editor)))
	UIManager.show_dialog(content, tr("team_settings"), true, BANNER_DIALOG_SIZE, false)
	_populate_join_requests(requests_box)


## Label + OptionButton (open / by-request) row; the option is the second child.
func _build_access_row(selected_index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = tr("team_access")
	row.add_child(label)
	var option := OptionButton.new()
	option.add_item(tr("team_access_open"), 0)
	option.add_item(tr("team_access_by_request"), 1)
	option.select(selected_index)
	row.add_child(option)
	return row


func _build_dialog_button_row(primary_text: String, on_primary: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var cancel_button := Button.new()
	cancel_button.theme_type_variation = "ButtonNav"
	cancel_button.text = tr("social_cancel")
	cancel_button.pressed.connect(UIManager.close_current_dialog)
	row.add_child(cancel_button)
	var primary_button := Button.new()
	primary_button.theme_type_variation = "ButtonAccent"
	primary_button.text = primary_text
	primary_button.pressed.connect(on_primary)
	row.add_child(primary_button)
	return row


func _on_create_team_pressed(name_edit: LineEdit, access_option: OptionButton, editor: TeamBannerEditor) -> void:
	var mode := ACCESS_BY_REQUEST if access_option.selected == 1 else ACCESS_OPEN
	var result: Dictionary = await SocialManager.create_team(str(name_edit.text), mode, editor.get_recipe())
	if not is_inside_tree():
		return
	if bool(result.get("ok", false)):
		UIManager.close_current_dialog()
	else:
		UIManager.push_toast(tr(_team_error_key(str(result.get("error", "")))), "cross")


func _on_save_team_settings_pressed(name_edit: LineEdit, access_option: OptionButton, editor: TeamBannerEditor) -> void:
	var mode := ACCESS_BY_REQUEST if access_option.selected == 1 else ACCESS_OPEN
	var settings := {
		"name": str(name_edit.text),
		"access_mode": mode,
		"banner_recipe": editor.get_recipe(),
	}
	var result: Dictionary = await SocialManager.update_team_settings(settings)
	if not is_inside_tree():
		return
	if bool(result.get("ok", false)):
		UIManager.close_current_dialog()
	else:
		UIManager.push_toast(tr(_team_error_key(str(result.get("error", "")))), "cross")


func _populate_join_requests(box: VBoxContainer) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	var requests: Array[Dictionary] = await SocialManager.fetch_join_requests()
	if not is_inside_tree():
		return
	for request in requests:
		box.add_child(_build_join_request_row(str(request.get("player_code", "")), str(request.get("name", "")), box))


func _build_join_request_row(player_code: String, name: String, box: VBoxContainer) -> PanelContainer:
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	panel.add_child(hbox)

	var name_label := Label.new()
	name_label.text = name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(name_label)

	var approve_button := Button.new()
	approve_button.theme_type_variation = "ButtonAccent"
	approve_button.text = tr("team_approve")
	approve_button.pressed.connect(_on_respond_join_request_pressed.bind(player_code, true, box))
	hbox.add_child(approve_button)

	var deny_button := Button.new()
	deny_button.theme_type_variation = "ButtonNav"
	deny_button.text = tr("team_deny")
	deny_button.pressed.connect(_on_respond_join_request_pressed.bind(player_code, false, box))
	hbox.add_child(deny_button)

	return panel


func _on_respond_join_request_pressed(player_code: String, approve: bool, box: VBoxContainer) -> void:
	await SocialManager.respond_join_request(player_code, approve)  # the team refresh re-renders members
	if not is_inside_tree():
		return
	_populate_join_requests(box)


# --- Actions ------------------------------------------------------------------------

func _on_subtab_pressed(button: Button) -> void:
	_select_subtab(_subtab_buttons.find(button))


func _on_find_team_pressed() -> void:
	_select_tab(2)


## Routes by access mode: open teams join directly, by-request teams send a
## join request. The manager writes the `team` domain + emits social_team_changed
## on success (which re-renders the Team tab); failures toast their error key.
func _on_join_pressed(team: Dictionary) -> void:
	if str(team.get("access_mode", ACCESS_OPEN)) == ACCESS_BY_REQUEST:
		await _on_request_join_pressed(str(team.get("team_id", "")))
		return
	var result: Dictionary = await SocialManager.join_team(str(team.get("team_id", "")))
	if not is_inside_tree():
		return
	if not bool(result.get("ok", false)):
		UIManager.push_toast(tr(_team_error_key(str(result.get("error", "")))), "cross")


func _on_request_join_pressed(team_id: String) -> void:
	var result: Dictionary = await SocialManager.request_join(team_id)
	if not is_inside_tree():
		return
	if bool(result.get("ok", false)):
		_refresh_results()
	else:
		UIManager.push_toast(tr(_team_error_key(str(result.get("error", "")))), "cross")


func _on_remove_friend_pressed(player_code: String) -> void:
	await SocialManager.remove_friend(player_code)  # the changed signal re-renders


func _on_block_pressed(player_code: String) -> void:
	await SocialManager.block_user(player_code)  # friends + invitations re-render via signals
	_refresh_blocked()


func _on_unblock_pressed(player_code: String) -> void:
	await SocialManager.unblock_user(player_code)
	_refresh_blocked()


func _on_respond_invitation_pressed(player_code: String, accept: bool) -> void:
	await SocialManager.respond_invitation(player_code, accept)  # both lists re-render via signals


func _on_add_friend_pressed() -> void:
	var code := str(_add_friend_edit.text).strip_edges()
	if code.is_empty():
		return
	var result: Dictionary = await SocialManager.add_friend(code)
	if not is_inside_tree():
		return
	if bool(result.get("ok", false)):
		_add_friend_edit.clear()
		_add_friend_error.visible = false
	else:
		_add_friend_error.text = tr(_friend_error_key(str(result.get("error", ""))))
		_add_friend_error.visible = true


func _on_team_changed(_team: Dictionary) -> void:
	_refresh_team()


# --- Online gating (TDD §3.18) ------------------------------------------------------

## On every connectivity transition the banner flips, the network-dependent
## controls re-gate, and the rows re-render from the manager's caches so row
## action buttons pick up the new gated state (cache fetches are local — no
## network is touched while offline).
func _on_backend_state_changed(_online: bool) -> void:
	_apply_online_gates(OnlineService.is_online())
	var friends := await SocialManager.fetch_friends()
	if not is_inside_tree():
		return
	_render_friends(friends)
	var invitations := await SocialManager.fetch_invitations()
	if not is_inside_tree():
		return
	_on_invitations_changed(invitations)
	_refresh_blocked()
	_refresh_results()


## Disables every network-dependent control. Mock mode never reaches the
## offline branch (is_online() is always true there), keeping the gate hermetic.
## NOTE (build quirk): this Godot build's LineEdit has neither Control.disabled
## nor read_only — only Button/OptionButton carry disabled — so edit fields are
## gated by making them unfocusable (no focus = no typing, no text_submitted).
func _apply_online_gates(online: bool) -> void:
	if _offline_banner != null:
		_offline_banner.text = "" if online else tr("common_offline")
	var edit_focus := Control.FOCUS_ALL if online else Control.FOCUS_NONE
	if _add_friend_edit != null:
		_add_friend_edit.focus_mode = edit_focus
	if _add_friend_button != null:
		_add_friend_button.disabled = not online
	if _find_team_button != null:
		_find_team_button.disabled = not online
	if _create_team_button != null:
		_create_team_button.disabled = not online
	if _settings_button != null:
		_settings_button.disabled = not online
	if _search_edit != null:
		_search_edit.focus_mode = edit_focus
	if _search_mode != null:
		_search_mode.disabled = not online
	if _chat_input != null:
		_chat_input.focus_mode = edit_focus
	if _chat_send_button != null:
		_chat_send_button.disabled = not online
	_refresh_chat_if_visible()


## Row action buttons are disabled while the backend is unverified (TDD §3.18).
func _actions_gated() -> bool:
	return not OnlineService.is_online()


# --- Helpers ------------------------------------------------------------------------

static func _recipe_from_domain(team: Dictionary) -> Dictionary:
	return {
		"base": str(team.get("banner_base", "")),
		"icon": str(team.get("banner_icon", "")),
		"base_lut": str(team.get("banner_base_lut", "")),
		"icon_lut": str(team.get("banner_icon_lut", "")),
		"icon_scale": float(team.get("banner_icon_scale", 1.0)),
	}


static func _recipe_from_row(team: Dictionary) -> Dictionary:
	var recipe: Variant = team.get("banner_recipe", {})
	if typeof(recipe) == TYPE_DICTIONARY:
		return (recipe as Dictionary).duplicate(true)
	return {}


## Legacy saves carry banner_color ("gold"/"blue"/"green") instead of a recipe;
## map it to the chip color TeamBannerView falls back to.
static func _legacy_banner_color(color_key: String) -> Color:
	match color_key:
		"gold":
			return ThemeFactory.COLOR_GOLD
		"blue":
			return ThemeFactory.COLOR_BLUE
		"green":
			return ThemeFactory.COLOR_GREEN
	return ThemeFactory.COLOR_PANEL


static func _access_key(mode: String) -> String:
	return "team_access_by_request" if mode == ACCESS_BY_REQUEST else "team_access_open"


## Presence suffix on the existing dim line (TDD §3.25): "Level 7" stays plain
## when offline-gated or no presence data exists; otherwise it gains "· online"
## or "· seen <relative>". `row_last_seen` is the storage-stamped fallback for
## offline friends the socket has not reported this session.
func _presence_line(base_text: String, player_code: String, row_last_seen: int = 0) -> String:
	if player_code.is_empty() or _actions_gated():
		return base_text
	var presence := SocialManager.get_presence(player_code)
	if bool(presence.get("online", false)):
		return "%s · %s" % [base_text, tr("social_presence_online")]
	var last_seen := int(presence.get("last_seen", 0))
	if last_seen <= 0:
		last_seen = row_last_seen
	if last_seen <= 0:
		return base_text
	return "%s · %s" % [base_text, _relative_time(last_seen)]


## Relative time for "seen X ago": now / minutes / hours / days, capped at 3d+.
## Non-static on purpose: tr() is an Object method in this Godot build and
## cannot be called from static context (parse error).
func _relative_time(ts: int) -> String:
	var delta := maxi(0, int(Time.get_unix_time_from_system()) - ts)
	if delta < 90:
		return tr("social_seen_now")
	if delta < 3600:
		return tr("social_seen_minutes") % [int(delta / 60)]
	if delta < 86400:
		return tr("social_seen_hours") % [int(delta / 3600)]
	var days := int(delta / 86400)
	if days >= 3:
		return tr("social_seen_days_cap")
	return tr("social_seen_days") % [days]


func _friend_error_key(error_key: String) -> String:
	match error_key:
		"friend_invalid_code":
			return "social_error_invalid_code"
		"friend_unknown_code":
			return "social_error_unknown_code"
		"friend_already_added":
			return "social_error_already_friend"
		"friend_pending_exists":
			return "social_error_pending_exists"
		"friend_blocked":
			return "social_error_blocked"
		"social_unavailable":
			return "social_error_unavailable"
	return "social_error_generic"


func _team_error_key(error_key: String) -> String:
	match error_key:
		"team_by_request":
			return "social_error_team_by_request"
		"team_open":
			return "social_error_team_open"
		"team_request_pending":
			return "social_error_request_pending"
		"team_already_member":
			return "social_error_already_member"
		"team_not_leader":
			return "social_error_not_leader"
		"team_invalid_name":
			return "social_error_invalid_name"
		"team_already_on_team":
			return "social_error_already_on_team"
		"social_unavailable":
			return "social_error_unavailable"
	return "social_error_generic"
