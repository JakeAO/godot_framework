extends GutTest
## Long-session stress (ROADMAP A4): the tap-target round runs for many real
## frames across repeated rounds, and a 30-round session is driven through the
## full round-end reward path. Asserts no script errors (GUT fails the test on
## any unconsumed error) and stable memory-ish behavior: the gameplay widget's
## live node count stays bounded by MAX_TARGETS (targets are the only children
## and queue_free'd on expiry), and long-run save state stays consistent
## (stage clamped at the ladder end, piggy balance capped, XP below the next
## level threshold). Config overrides make spawn/expiry churn dense so a full
## session takes seconds, not minutes.

const ROUND_COUNT: int = 8
## Frames pumped per round before giving up; a 1s round needs ~60 at 60fps,
## so this allows a slow machine a 15x margin.
const PUMP_CAP: int = 900
const SESSION_ROUNDS: int = 30

var _host: Control
var _mounted: Array[BaseScreen] = []
var _original_path: String = ""
var _temp_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	# The shipped ladder is the state this file's assertions assume.
	StageCatalog.load_stages(Paths.STAGES_DIR)
	_host = Control.new()
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)
	# Round ends emit navigation_requested without an attached shell; silence
	# the pre-attach warning for the duration of this file.
	if EventBus.navigation_requested.is_connected(ScreenManager._on_navigation_requested):
		EventBus.navigation_requested.disconnect(ScreenManager._on_navigation_requested)


func after_all() -> void:
	if not EventBus.navigation_requested.is_connected(ScreenManager._on_navigation_requested):
		EventBus.navigation_requested.connect(ScreenManager._on_navigation_requested)
	UIManager.cancel_tutorial()
	UIManager.clear_toasts()
	if is_instance_valid(_host):
		_host.queue_free()


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/stress_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()


func after_each() -> void:
	for screen in _mounted:
		if is_instance_valid(screen):
			screen.queue_free()
	_mounted.clear()
	UIManager.cancel_tutorial()
	UIManager.clear_toasts()
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	# Clear the dense-churn config overrides + forced variant.
	RemoteConfig.fetch()


func test_repeated_rounds_keep_widget_node_count_bounded() -> void:
	RemoteConfig.set_value("round_duration_sec", 1.0)
	RemoteConfig.set_value("target_lifetime_sec", 0.2)
	RemoteConfig.force_variant("target_spawn_rate", "fast")
	var screen := _mount(GameScreen.new())
	await _settle_layout()
	var gameplay: Variant = screen._gameplay
	assert_true(gameplay is TapTargetGameplay, "stage-selected widget is the tap-target round")
	var tap: TapTargetGameplay = gameplay
	var max_mid_round_targets := 0
	for r in ROUND_COUNT:
		if not tap.is_running:
			screen._start_round()
		assert_true(tap.is_running, "round %d is running" % (r + 1))
		var frames := 0
		while tap.is_running and frames < PUMP_CAP:
			max_mid_round_targets = maxi(max_mid_round_targets, tap._targets.size())
			await get_tree().process_frame
			frames += 1
		assert_false(tap.is_running, "round %d completed within the frame cap" % (r + 1))
		# Let queue_free flush the expired targets before counting.
		await _settle_layout(3)
		var live := _descendant_count(tap)
		assert_lte(live, TapTargetGameplay.MAX_TARGETS, "round %d ends with at most MAX_TARGETS live nodes (got %d)" % [r + 1, live])
	assert_true(max_mid_round_targets > 0, "targets actually spawned during the rounds")
	var total_games := int(SaveSystem.get_value("profile", "total_games", -1))
	assert_eq(total_games, ROUND_COUNT, "every pumped round completed its full reward path")


func test_long_session_save_state_stays_consistent() -> void:
	RemoteConfig.set_value("win_score", 0)
	RemoteConfig.set_value("piggy_bank_capacity", 25)
	var screen := _mount(GameScreen.new())
	for r in SESSION_ROUNDS:
		screen._on_round_ended(100 + (r % 7))
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("total_games", -1)), SESSION_ROUNDS, "every round counted")
	assert_eq(int(profile.get("stage", -1)), StageCatalog.stage_count(), "stage clamped at the ladder end after repeated wins")
	assert_almost_eq(float(SaveSystem.get_value("piggy_bank", "balance", -1)), 25.0, 0.001, "piggy balance capped at the small capacity (bounded growth)")
	assert_eq(int(profile.get("best_score", -1)), 106, "best score is the session maximum")
	var level := int(profile.get("level", -1))
	var xp := int(profile.get("xp", -1))
	assert_true(level >= 1, "level stays sane over a long session")
	assert_true(xp >= 0 and xp < Scoring.xp_needed_for_level(level), "leftover XP always below the next-level threshold")


# --- Helpers --------------------------------------------------------------------

func _mount(screen: BaseScreen) -> BaseScreen:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


func _descendant_count(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		count += 1 + _descendant_count(child)
	return count


func _settle_layout(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame
