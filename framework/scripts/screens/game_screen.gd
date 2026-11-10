class_name GameScreen extends BaseScreen
## Fullscreen gameplay screen. Hosts the stage-selected GameplayBase widget
## (GameplayRegistry key from the StageDefinition, with the global remote
## `gameplay_scene` override), a HUD with live score/timer and a pause button
## (ESC/P), and an in-screen pause overlay. Starts a fresh round every time it
## is shown; when the round ends it applies rewards to the save (best score,
## coins via the "results_coin_multiplier" experiment, stage progression past
## the stage's effective win_score) and navigates to Results with the finished
## GameResult.

const PROFILE_DOMAIN: String = "profile"
const STAGE_KEY: String = "stage"
const COINS_KEY: String = "coins"
const BEST_SCORE_KEY: String = "best_score"
const TOTAL_GAMES_KEY: String = "total_games"
const LEVEL_KEY: String = "level"
const XP_KEY: String = "xp"
const PIGGY_DOMAIN: String = "piggy_bank"
const PIGGY_BALANCE_KEY: String = "balance"
const PIGGY_CAPACITY_KEY: String = "piggy_bank_capacity"
const DEFAULT_PIGGY_CAPACITY: int = 200
const PIGGY_DEPOSIT_KEY: String = "piggy_deposit_per_stage"
const DEFAULT_PIGGY_DEPOSIT: int = 10
const GAMEPLAY_OVERRIDE_KEY: String = "gameplay_scene"

var _gameplay: GameplayBase = null
var _score_label: Label = null
var _timer_label: Label = null
var _pause_button: Button = null
var _overlay: PanelContainer = null
var _overlay_title: Label = null
var _resume_button: Button = null
var _quit_button: Button = null

var _round_duration_sec: float = 30.0
# Raw-value caches (B3): the HUD refreshes every frame, so dedupe on the int
# instead of formatting a string (+ tr() lookup) per frame to compare.
var _last_score: int = -1
var _last_seconds_left: int = -1


func _ready() -> void:
	super._ready()
	_start_round()


func _exit_tree() -> void:
	if _gameplay != null and _gameplay.round_ended.is_connected(_on_round_ended):
		_gameplay.round_ended.disconnect(_on_round_ended)
	super._exit_tree()


func _process(_delta: float) -> void:
	_refresh_hud()


func _apply_locale() -> void:
	if _pause_button != null:
		_pause_button.text = tr("game_pause")
	if _overlay_title != null:
		_overlay_title.text = tr("game_pause")
	if _resume_button != null:
		_resume_button.text = tr("game_resume")
	if _quit_button != null:
		_quit_button.text = tr("game_quit")
	_last_score = -1
	_last_seconds_left = -1
	_refresh_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and _gameplay != null and _gameplay.is_running:
		_on_pause_toggled()


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
	vbox.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	margin.add_child(vbox)

	var hud := HBoxContainer.new()
	hud.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	vbox.add_child(hud)

	_score_label = Label.new()
	_score_label.theme_type_variation = &"LabelGold"
	_score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	hud.add_child(_score_label)

	_timer_label = Label.new()
	_timer_label.theme_type_variation = &"LabelDim"
	hud.add_child(_timer_label)

	_pause_button = Button.new()
	_pause_button.theme_type_variation = &"ButtonNav"
	_pause_button.pressed.connect(_on_pause_toggled)
	hud.add_child(_pause_button)

	# The screen is cached and built once, so the widget is created for the
	# stage at first mount; start_round() resets its state on every showing.
	var stage: int = _current_stage()
	_gameplay = GameplayRegistry.create(_effective_gameplay_key(stage))
	_gameplay.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gameplay.round_ended.connect(_on_round_ended)
	vbox.add_child(_gameplay)

	_overlay = _build_pause_overlay()
	add_child(_overlay)


func _build_pause_overlay() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = ThemeFactory.COLOR_BG.darkened(0.4)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	panel.add_child(vbox)

	_overlay_title = Label.new()
	_overlay_title.theme_type_variation = &"LabelTitle"
	_overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_overlay_title)

	_resume_button = Button.new()
	_resume_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_resume_button.pressed.connect(_on_pause_toggled)
	vbox.add_child(_resume_button)

	_quit_button = Button.new()
	_quit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quit_button.pressed.connect(_on_quit_pressed)
	vbox.add_child(_quit_button)

	return panel


# --- Round lifecycle ------------------------------------------------------------

func _start_round() -> void:
	if _gameplay == null:
		return
	var stage: int = _current_stage()
	_round_duration_sec = StageCatalog.effective_duration(stage)
	_gameplay.start_round(_round_duration_sec)
	if _overlay != null:
		_overlay.visible = false
	EventBus.gameplay_started.emit({
		"stage": stage,
		"duration_sec": _round_duration_sec,
		"gameplay": _effective_gameplay_key(stage),
	})


func _on_pause_toggled() -> void:
	if _gameplay == null or not _gameplay.is_running:
		return
	var next_paused := not _gameplay.is_paused
	_gameplay.set_paused(next_paused)
	if _overlay != null:
		_overlay.visible = next_paused


func _on_quit_pressed() -> void:
	if _gameplay != null:
		_gameplay.stop()
	if _overlay != null:
		_overlay.visible = false
	EventBus.navigation_requested.emit(ScreenIds.HOME)


## The playable stage for this screen: the saved value clamped to the ladder
## (a save from a longer ladder degrades gracefully — GDD §5).
func _current_stage() -> int:
	var raw: int = int(SaveSystem.get_value(PROFILE_DOMAIN, STAGE_KEY, 1))
	return clampi(raw, 1, maxi(StageCatalog.stage_count(), 1))


## The gameplay key for a stage: the global remote `gameplay_scene` override
## wins when set, otherwise the stage's own key (GDD §5).
func _effective_gameplay_key(stage_id: int) -> String:
	var override := str(RemoteConfig.get_value(GAMEPLAY_OVERRIDE_KEY, ""))
	if override != "":
		return override
	return str(StageCatalog.get_stage(stage_id).gameplay_key)


# --- Rewards --------------------------------------------------------------------

func _on_round_ended(final_score: int) -> void:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	var previous_best: int = int(profile.get(BEST_SCORE_KEY, 0))
	var is_new_best := final_score > previous_best
	var best_score := maxi(previous_best, final_score)

	var multiplier := float(RemoteConfig.get_experiment_param("results_coin_multiplier", "multiplier", 1.0))
	RemoteConfig.log_experiment_exposure("results_coin_multiplier")
	var coins_earned: int = Scoring.coins_for_score(final_score, multiplier)

	# Campaign modifiers (GDD §6): active modifier campaigns scale the round
	# value multiplicatively; applied ones are surfaced on Results + analytics.
	var modifiers_applied: Array[Dictionary] = []
	var coins_mult := 1.0
	var xp_mult := 1.0
	for campaign in RemoteConfig.get_campaigns():
		if str(campaign.get("action", "")) != "modifier":
			continue
		var campaign_id := str(campaign.get("id", ""))
		if not RemoteConfig.is_campaign_active(campaign_id):
			continue
		var stat := str(campaign.get("modifies", ""))
		var mod_mult := float(campaign.get("multiplier", 1.0))
		if (stat != "coins" and stat != "xp") or mod_mult <= 0.0:
			continue
		if stat == "coins":
			coins_mult *= mod_mult
		else:
			xp_mult *= mod_mult
		modifiers_applied.append({
			"stat": stat,
			"multiplier": mod_mult,
			"title": str(campaign.get("title", "")),
		})
	coins_earned = int(roundf(float(coins_earned) * coins_mult))

	var won := final_score >= StageCatalog.effective_win_score(_current_stage())
	var stage: int = _current_stage()
	if won and stage < StageCatalog.stage_count():
		stage += 1
	var coins: int = int(profile.get(COINS_KEY, 0)) + coins_earned

	profile[BEST_SCORE_KEY] = best_score
	profile[TOTAL_GAMES_KEY] = int(profile.get(TOTAL_GAMES_KEY, 0)) + 1
	profile[STAGE_KEY] = stage
	profile[COINS_KEY] = coins

	# XP / levels (GDD §5/§6): XP == (modified) coins earned, then its own
	# modifier stack; level-ups cascade.
	var xp_earned: int = int(roundf(float(coins_earned) * xp_mult))
	var previous_level: int = int(profile.get(LEVEL_KEY, 1))
	var level := previous_level
	var xp: int = int(profile.get(XP_KEY, 0)) + xp_earned
	while xp >= Scoring.xp_needed_for_level(level):
		xp -= Scoring.xp_needed_for_level(level)
		level += 1
	profile[LEVEL_KEY] = level
	profile[XP_KEY] = xp

	# Daily streak (GDD §8): every completed round counts toward today's goal.
	var today := Time.get_date_string_from_system()
	profile = StreakLogic.register_round(profile, today)

	# Piggy bank deposit (GDD §6, Phase F2): a fixed per-stage amount ONLY on a
	# won round, capped at capacity (replaces the old per-round coins/5 rule).
	var piggy: Dictionary = SaveSystem.get_domain(PIGGY_DOMAIN)
	if won:
		var capacity: int = maxi(int(RemoteConfig.get_value(PIGGY_CAPACITY_KEY, DEFAULT_PIGGY_CAPACITY)), 0)
		var deposit: int = maxi(int(RemoteConfig.get_value(PIGGY_DEPOSIT_KEY, DEFAULT_PIGGY_DEPOSIT)), 0)
		piggy[PIGGY_BALANCE_KEY] = mini(int(piggy.get(PIGGY_BALANCE_KEY, 0)) + deposit, capacity)
	else:
		piggy[PIGGY_BALANCE_KEY] = int(piggy.get(PIGGY_BALANCE_KEY, 0))

	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.set_domain(PIGGY_DOMAIN, piggy)
	SaveSystem.save_game()
	EventBus.currency_changed.emit("coins", int(SaveSystem.get_value(PROFILE_DOMAIN, COINS_KEY, coins)))
	EventBus.profile_updated.emit(SaveSystem.get_domain(PROFILE_DOMAIN))
	if won:
		EventBus.piggy_bank_changed.emit(int(piggy.get(PIGGY_BALANCE_KEY, 0)))
	if level > previous_level:
		EventBus.level_upped.emit(level)
		UIManager.push_toast(tr("toast_level_up") % [level], "xp", Callable(), true)

	Analytics.track("game_finished", {
		"stage": stage,
		"score": final_score,
		"best_score": best_score,
		"is_new_best": is_new_best,
		"coins_earned": coins_earned,
		"xp_earned": xp_earned,
		"won": won,
		"modifiers_applied": modifiers_applied,
	})

	var result := GameResult.new()
	result.stage_id = stage
	result.score = final_score
	result.best_score = best_score
	result.is_new_best = is_new_best
	result.coins_earned = coins_earned
	result.xp_earned = xp_earned
	result.won = won
	result.modifiers_applied = modifiers_applied
	if _gameplay != null:
		result.duration_sec = _gameplay.elapsed_sec

	# navigation_requested first: it mounts ResultsScreen synchronously, whose
	# _ready() connects to gameplay_finished. Emitting the result afterwards
	# guarantees the listener exists.
	EventBus.navigation_requested.emit(ScreenIds.RESULTS)
	EventBus.gameplay_finished.emit(result.to_dict())


# --- HUD ------------------------------------------------------------------------

func _refresh_hud() -> void:
	if _gameplay == null or _score_label == null or _timer_label == null:
		return
	var score := int(_gameplay.current_score)
	if score != _last_score:
		_last_score = score
		_score_label.text = "%s: %d" % [tr("results_score"), score]
	var seconds_left := int(ceili(maxf(_round_duration_sec - _gameplay.elapsed_sec, 0.0)))
	if seconds_left != _last_seconds_left:
		_last_seconds_left = seconds_left
		_timer_label.text = str(seconds_left)
