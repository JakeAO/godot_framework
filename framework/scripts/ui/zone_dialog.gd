class_name ZoneDialog
extends Control
## State-driven content for zone widget dialogs (GDD §8 / TDD §3.21). ScreenShell
## builds one per tap and hands it to UIManager.show_dialog(); it renders from
## live save/config state at open, refreshes on the relevant EventBus signals
## while open, and reports button presses via action_requested — the shell owns
## every save mutation. Sprite-art kinds (gift/bank) host an idle-looping
## OfferSpriteWidget; play_opening_then_close() runs the one-shot opening clip
## before asking the shell to close the dialog.

signal action_requested(action: String)
signal closed_requested

const DAILY_GIFT_KIND: String = "daily_gift"
const PIGGY_BANK_KIND: String = "piggy_bank"
const STREAK_KIND: String = "streak"
const CLAIM_KIND: String = "claim"
const INFO_KIND: String = "info"
const TOURNAMENT_KIND: String = "tournament"
const LEADERBOARDS_KIND: String = "leaderboards"
const MATCHMAKING_KIND: String = "matchmaking"

const ACTION_CLAIM: String = "claim"
const ACTION_TOURNAMENT_CLAIM: String = "tournament_claim"
const ACTION_MATCHMAKING_FIND: String = "matchmaking_find"
const ACTION_MATCHMAKING_CANCEL: String = "matchmaking_cancel"
const ACTION_MATCHMAKING_LEAVE: String = "matchmaking_leave"
const ACTION_WATCH_CLAIM: String = "watch_claim"
const ACTION_COLLECT_RV: String = "collect_rv"
const ACTION_COLLECT_IAP: String = "collect_iap"
const ACTION_RECOVER_COINS: String = "recover_coins"
const ACTION_RECOVER_RV: String = "recover_rv"

const PROFILE_DOMAIN: String = "profile"
const OFFERS_DOMAIN: String = "offers"
const PIGGY_BANK_DOMAIN: String = "piggy_bank"
const TEAM_DOMAIN: String = "team"

const DAILY_GIFT_EXTRA_WATCHES_KEY: String = "daily_gift_extra_watches"
const DEFAULT_DAILY_GIFT_EXTRA_WATCHES: int = 2
const PIGGY_CAPACITY_KEY: String = "piggy_bank_capacity"
const DEFAULT_PIGGY_CAPACITY: int = 200
const PIGGY_THRESHOLD_KEY: String = "piggy_redemption_threshold"
const DEFAULT_PIGGY_THRESHOLD: int = 150
const PIGGY_DEPOSIT_KEY: String = "piggy_deposit_per_stage"
const DEFAULT_PIGGY_DEPOSIT: int = 10

const SPRITE_SIZE: float = 96.0

var kind: String = ""
var entry: Dictionary = {}
## "offer" | "campaign" — cooldown rules only apply to offers.
var source: String = ""
var icon_key: String = ""

var _root: VBoxContainer
var _body_box: VBoxContainer
var _sprite: OfferSpriteWidget = null
var _countdown_label: Label = null
var _timer: Timer
var _note: String = ""
var _playing_opening: bool = false
## Leaderboards dialog scope (TDD §3.26); persists across refreshes while open.
var _lb_scope: String = "global"


## Stores the dialog's inputs; the UI is built in _ready() (after the shell has
## added this control to the tree via UIManager.show_dialog).
func setup(p_kind: String, p_entry: Dictionary, p_source: String, p_icon_key: String) -> void:
	kind = p_kind
	entry = p_entry.duplicate(true)
	source = p_source
	icon_key = p_icon_key


func _ready() -> void:
	_build_root()
	EventBus.profile_updated.connect(_on_profile_updated)
	EventBus.currency_changed.connect(_on_currency_changed)
	EventBus.piggy_bank_changed.connect(_on_piggy_changed)
	EventBus.matchmaking_state_changed.connect(_on_matchmaking_state_changed)
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.autostart = true
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	refresh()


func _exit_tree() -> void:
	if EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.disconnect(_on_profile_updated)
	if EventBus.currency_changed.is_connected(_on_currency_changed):
		EventBus.currency_changed.disconnect(_on_currency_changed)
	if EventBus.piggy_bank_changed.is_connected(_on_piggy_changed):
		EventBus.piggy_bank_changed.disconnect(_on_piggy_changed)
	if EventBus.matchmaking_state_changed.is_connected(_on_matchmaking_state_changed):
		EventBus.matchmaking_state_changed.disconnect(_on_matchmaking_state_changed)


## Re-renders the body from live save/config state. No-op while the opening
## clip is playing (the dialog closes right after — a rebuild would free the
## sprite mid-clip).
func refresh() -> void:
	if _playing_opening or _body_box == null:
		return
	for child in _body_box.get_children():
		_body_box.remove_child(child)
		child.queue_free()
	_countdown_label = null
	if _note != "":
		_add_note(_note)
	match kind:
		DAILY_GIFT_KIND:
			_render_daily_gift()
		PIGGY_BANK_KIND:
			_render_piggy()
		STREAK_KIND:
			_render_streak()
		CLAIM_KIND:
			_render_claim()
		INFO_KIND:
			_render_info()
		TOURNAMENT_KIND:
			_render_tournament()
		LEADERBOARDS_KIND:
			_render_leaderboards()
		MATCHMAKING_KIND:
			_render_matchmaking()


## Inline transient line (e.g. a failed RV watch) shown above the body until the
## next refresh.
func set_note(text: String) -> void:
	_note = text
	refresh()


## Plays the sprite's one-shot opening clip, then requests close; kinds without
## sprite art request close immediately.
func play_opening_then_close() -> void:
	if _sprite != null and is_inside_tree():
		_playing_opening = true
		_sprite.play_opening(Callable(self, "_on_opening_finished"))
	else:
		closed_requested.emit()


# --- Rendering -------------------------------------------------------------------

func _build_root() -> void:
	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 12)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var frames_path := OfferSpriteWidget.frames_path_for_icon(icon_key)
	if frames_path != "":
		_sprite = _make_sprite(frames_path)
	if _sprite != null:
		var center := CenterContainer.new()
		center.add_child(_sprite)
		_root.add_child(center)
	_body_box = VBoxContainer.new()
	_body_box.add_theme_constant_override("separation", 8)
	_body_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(_body_box)


func _make_sprite(frames_path: String) -> OfferSpriteWidget:
	var widget := OfferSpriteWidget.new()
	widget.setup(frames_path, SPRITE_SIZE)
	return widget


func _render_daily_gift() -> void:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	var today := Time.get_date_string_from_system()
	var claimed_today := str(profile.get("last_daily_claim_day", "")) == today
	var cap := maxi(int(RemoteConfig.get_value(DAILY_GIFT_EXTRA_WATCHES_KEY, DEFAULT_DAILY_GIFT_EXTRA_WATCHES)), 0)
	var count := int(profile.get("daily_gift_watches_count", 0)) if str(profile.get("daily_gift_watches_date", "")) == today else 0
	if not claimed_today:
		_add_body(tr("dlg_daily_gift_free"))
		_add_button(tr("offer_claim"), ACTION_CLAIM)
	elif cap - count > 0:
		_add_body(tr("dlg_daily_gift_extras") % [cap - count])
		_add_button(tr("dlg_daily_gift_watch_btn"), ACTION_WATCH_CLAIM)
	else:
		_add_body(tr("dlg_daily_gift_done"))
		_countdown_label = _add_dim(tr("dlg_daily_gift_next_in") % _hm(_seconds_to_midnight()))


func _render_piggy() -> void:
	var bank: Dictionary = SaveSystem.get_domain(PIGGY_BANK_DOMAIN)
	var balance := int(bank.get("balance", 0))
	var capacity := maxi(int(RemoteConfig.get_value(PIGGY_CAPACITY_KEY, DEFAULT_PIGGY_CAPACITY)), 0)
	var threshold := maxi(int(RemoteConfig.get_value(PIGGY_THRESHOLD_KEY, DEFAULT_PIGGY_THRESHOLD)), 0)
	var deposit := maxi(int(RemoteConfig.get_value(PIGGY_DEPOSIT_KEY, DEFAULT_PIGGY_DEPOSIT)), 0)
	var gauge := ProgressBar.new()
	gauge.show_percentage = false
	gauge.max_value = float(maxi(capacity, 1))
	gauge.value = float(mini(balance, capacity))
	_body_box.add_child(gauge)
	_add_dim("%d / %d" % [balance, capacity])
	if balance >= threshold:
		_add_body(tr("dlg_piggy_ready"))
		_add_button(tr("dlg_piggy_collect_rv"), ACTION_COLLECT_RV)
		_add_button(tr("dlg_piggy_collect_iap"), ACTION_COLLECT_IAP)
	else:
		_add_body(tr("dlg_piggy_filling") % [deposit, maxi(threshold - balance, 0)])


func _render_streak() -> void:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	var today := Time.get_date_string_from_system()
	var rounds := int(profile.get("streak_rounds_today", 0)) if str(profile.get("streak_date", "")) == today else 0
	_add_body(tr("dlg_streak_current") % [int(profile.get("streak_days", 0))])
	if StreakLogic.is_claimable(profile, today):
		_add_body(tr("dlg_streak_ready"))
		_add_button(tr("offer_claim"), ACTION_CLAIM)
	elif StreakLogic.can_recover(profile, today):
		_add_body(tr("dlg_streak_broken"))
		var cost := StreakLogic.recovery_cost()
		_add_button(tr("dlg_streak_recover_coins") % [cost], ACTION_RECOVER_COINS, int(profile.get("coins", 0)) >= cost)
		_add_button(tr("dlg_streak_recover_rv"), ACTION_RECOVER_RV)
	else:
		_add_body(tr("dlg_streak_progress") % [rounds, StreakLogic.min_rounds()])


func _render_claim() -> void:
	var amount := int(entry.get("reward_amount", 0))
	var currency := str(entry.get("reward_currency", "coins"))
	var currency_name := tr("header_gems") if currency == "gems" else tr("header_coins")
	_add_body(tr("dlg_offer_body") % [amount, currency_name])
	if source == "offer":
		var remaining := _cooldown_remaining_sec()
		if remaining > 0:
			_countdown_label = _add_dim(tr("offer_ready_in") % _hm(remaining))
			return
	_add_button(tr("offer_claim"), ACTION_CLAIM)


func _render_info() -> void:
	var subtitle := str(entry.get("subtitle", ""))
	if subtitle != "":
		_add_body(subtitle)


## Tournament (TDD §3.23): live standings + own rank + reward bands; a [Claim]
## button appears only after the event expires with an unclaimed entry. Offline /
## mock = disabled state, never faked (GDD §8 gating table).
func _render_tournament() -> void:
	var event_id := str(entry.get("id", ""))
	if not TournamentService.is_available():
		_add_body(tr("dlg_tournament_offline"))
		return
	if str(entry.get("kind", "")) == TournamentService.KIND_TEAM and not _on_team():
		_add_body(tr("dlg_tournament_no_team"))
		return
	var entry_state: Dictionary = TournamentService.get_entry(event_id)
	var active := RemoteConfig.is_event_active(event_id)
	var claimed := int(entry_state.get("claimed_unix", 0)) != 0
	if not active and entry_state.is_empty():
		_add_body(tr("dlg_tournament_missed"))
		return
	if active:
		if entry_state.is_empty():
			_add_dim(tr("dlg_tournament_enter_hint"))
		else:
			_add_body(tr("dlg_tournament_progress") % int(entry_state.get("progress", 0)))
	var standings_label := _add_dim(tr("dlg_tournament_loading"))
	_load_standings(event_id, standings_label)
	_add_reward_bands()
	if not active:
		if claimed:
			_add_dim(tr("dlg_tournament_claimed"))
		else:
			_add_button(tr("offer_claim"), ACTION_TOURNAMENT_CLAIM)


## Fills the standings label in place (top-N rows + own rank). The label is
## captured per call — a refresh that frees it mid-fetch makes the write a no-op.
func _load_standings(event_id: String, label: Label) -> void:
	var result: Dictionary = await TournamentService.fetch_standings(event_id)
	if not is_instance_valid(label):
		return
	if not bool(result.get("ok", false)):
		label.text = tr("dlg_tournament_offline")
		return
	var lines := ""
	var top: Array = result.get("top", [])
	for raw in top:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row := raw as Dictionary
		lines += "%d. %s — %d\n" % [int(row.get("rank", 0)), str(row.get("name", "")), int(row.get("score", 0))]
	var own_rank := int(result.get("own_rank", 0))
	if own_rank > 0:
		lines += tr("dlg_tournament_rank") % [own_rank, int(result.get("own_score", 0))]
	label.text = lines.strip_edges() if lines != "" else "—"


## Leaderboards (TDD §3.26): Global/Friends scope toggle + top-N rows, with the
## own-rank row pinned at the bottom (merged in by the service even when outside
## top-N). Offline / mock = disabled state, never faked (GDD §8 gating table).
func _render_leaderboards() -> void:
	if not LeaderboardService.is_available():
		_add_body(tr("dlg_leaderboards_offline"))
		return
	var toggle := HBoxContainer.new()
	toggle.add_theme_constant_override("separation", 8)
	for scope in [LeaderboardService.SCOPE_GLOBAL, LeaderboardService.SCOPE_FRIENDS]:
		var label := tr("dlg_leaderboards_scope_global") if scope == LeaderboardService.SCOPE_GLOBAL else tr("dlg_leaderboards_scope_friends")
		var button := Button.new()
		button.text = label
		button.toggle_mode = true
		button.button_pressed = _lb_scope == scope
		button.pressed.connect(_on_lb_scope_pressed.bind(scope))
		toggle.add_child(button)
	_body_box.add_child(toggle)
	var rows_label := _add_dim(tr("dlg_leaderboards_loading"))
	_load_leaderboard_rows(rows_label)


## Fills the leaderboard rows label in place. The label is captured per call — a
## refresh (scope toggle / profile update) that frees it mid-fetch makes the
## write a no-op.
func _load_leaderboard_rows(label: Label) -> void:
	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(_lb_scope)
	if not is_instance_valid(label):
		return
	var lines := ""
	for row in rows:
		lines += "%d. %s — %d\n" % [int(row.get("rank", 0)), str(row.get("name", "")), int(row.get("score", 0))]
	label.text = lines.strip_edges() if lines != "" else tr("dlg_leaderboards_empty")


func _on_lb_scope_pressed(scope: String) -> void:
	_lb_scope = scope
	refresh()


## Matchmaking (TDD §3.27): state-driven from MatchmakingService — idle [Find
## match] / queued [Cancel] / matched+in_match opponent rows (+[Leave] once the
## room is live). Offline / mock = disabled state, never faked (GDD §8 gating
## table). The 15s server matchmaker interval means "queued" is indeterminate —
## no countdown promise.
func _render_matchmaking() -> void:
	if not MatchmakingService.is_available():
		_add_body(tr("dlg_matchmaking_offline"))
		return
	match MatchmakingService.get_state():
		MatchmakingService.STATE_QUEUED:
			_add_body(tr("dlg_matchmaking_queued"))
			_add_button(tr("matchmaking_cancel"), ACTION_MATCHMAKING_CANCEL)
		MatchmakingService.STATE_MATCHED, MatchmakingService.STATE_IN_MATCH:
			_render_matchmaking_opponents()
			if MatchmakingService.get_state() == MatchmakingService.STATE_IN_MATCH:
				_add_button(tr("matchmaking_leave"), ACTION_MATCHMAKING_LEAVE)
		_:
			_add_body(tr("dlg_matchmaking_idle"))
			_add_button(tr("matchmaking_find"), ACTION_MATCHMAKING_FIND)


func _render_matchmaking_opponents() -> void:
	var opponents: Array[Dictionary] = MatchmakingService.get_opponents()
	if opponents.is_empty():
		_add_dim(tr("dlg_matchmaking_matched"))
		return
	_add_body(tr("dlg_matchmaking_matched"))
	for opponent in opponents:
		_add_dim(str(opponent.get("player_code", "")))


## Live queue/match transitions re-render while the dialog is open (the service
## emits on every transition; queued->matched can arrive ~15s after the tap).
func _on_matchmaking_state_changed(_state: String, _payload: Dictionary) -> void:
	if kind == MATCHMAKING_KIND:
		refresh()


func _add_reward_bands() -> void:
	var rewards: Variant = entry.get("rewards", [])
	if typeof(rewards) != TYPE_ARRAY or (rewards as Array).is_empty():
		return
	var lines := ""
	for raw in rewards as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var band := raw as Dictionary
		var currency_name := tr("header_gems") if str(band.get("currency", "coins")) == "gems" else tr("header_coins")
		lines += _rank_range(band) + " — %d %s\n" % [int(band.get("amount", 0)), currency_name]
	if lines != "":
		_add_dim(lines.strip_edges())


static func _rank_range(band: Dictionary) -> String:
	var lo := int(band.get("min_rank", 1))
	var hi := int(band.get("max_rank", lo))
	return "%d" % lo if lo == hi else "%d–%d" % [lo, hi]


func _on_team() -> bool:
	var team: Dictionary = SaveSystem.get_domain(TEAM_DOMAIN)
	return bool(team.get("on_team", false))


# --- Building blocks ---------------------------------------------------------------

func _add_body(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_box.add_child(label)
	return label


func _add_dim(text: String) -> Label:
	var label := _add_body(text)
	label.theme_type_variation = "LabelDim"
	return label


func _add_note(text: String) -> Label:
	var label := _add_body(text)
	label.theme_type_variation = "LabelGold"
	return label


func _add_button(text: String, action: String, enabled: bool = true) -> Button:
	var button := Button.new()
	button.text = text
	button.theme_type_variation = "ButtonPrimary"
	button.disabled = not enabled
	button.pressed.connect(_on_action_pressed.bind(action))
	_body_box.add_child(button)
	return button


# --- Internals ---------------------------------------------------------------------

func _on_action_pressed(action: String) -> void:
	action_requested.emit(action)


func _on_opening_finished() -> void:
	_playing_opening = false
	closed_requested.emit()


func _cooldown_remaining_sec() -> int:
	if source != "offer":
		return 0
	var offers: Dictionary = SaveSystem.get_domain(OFFERS_DOMAIN)
	var last := int(offers.get(str(entry.get("id", "")), 0))
	if last == 0:
		return 0
	var cooldown_sec := int(int(entry.get("cooldown_hours", 0)) * 3600.0)
	var now := int(Time.get_unix_time_from_system())
	return maxi(last + cooldown_sec - now, 0)


func _seconds_to_midnight() -> int:
	var dt: Dictionary = Time.get_time_dict_from_system()
	var sec_of_day := int(dt.get("hour", 0)) * 3600 + int(dt.get("minute", 0)) * 60 + int(dt.get("second", 0))
	return 86400 - sec_of_day


## [hours, minutes] for "%d:%02d" countdown strings (float division + casts,
## matching the project convention).
func _hm(total_sec: int) -> Array[int]:
	return [int(total_sec / 3600.0), int((total_sec % 3600) / 60.0)]


func _on_tick() -> void:
	if _countdown_label == null or not is_instance_valid(_countdown_label):
		return
	match kind:
		DAILY_GIFT_KIND:
			_countdown_label.text = tr("dlg_daily_gift_next_in") % _hm(_seconds_to_midnight())
		CLAIM_KIND:
			var remaining := _cooldown_remaining_sec()
			if remaining <= 0:
				refresh()
			else:
				_countdown_label.text = tr("offer_ready_in") % _hm(remaining)


func _on_profile_updated(_profile: Dictionary) -> void:
	refresh()


func _on_currency_changed(_currency: String, _amount: int) -> void:
	refresh()


func _on_piggy_changed(_balance: int) -> void:
	refresh()
