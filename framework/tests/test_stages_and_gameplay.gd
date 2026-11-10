extends GutTest
## Data-driven stages (GDD §5): the StageCatalog ladder, effective-value
## fallbacks (stage value ≤ 0 → remote default), GameplayRegistry selection
## and unknown-key fallback, and the GameScreen / HomeScreen wiring. Screens
## mount directly on a phone-sized host; the save is redirected per test and
## the catalog is pointed at a temp dir for custom-ladder tests.

const TEMP_STAGE_DIR: String = "user://gut_tmp/stages_test/"

var _host: Control
var _mounted: Array[BaseScreen] = []
var _original_path: String = ""
var _temp_path: String = ""
var _started_context: Dictionary = {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	DirAccess.make_dir_recursive_absolute(TEMP_STAGE_DIR)
	_host = Control.new()
	# Phone-sized test host: screens are full-rect anchored under it, so their
	# internal layout is computed against a realistic 720x1280 content area.
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)
	# These tests emit navigation_requested without an attached shell; silence
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
	_temp_path = "user://gut_tmp/stages_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	_wipe_stage_dir()
	_started_context = {}


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
	# Restore the shipped ladder, drop test-registered gameplay keys, and clear
	# any in-memory config overrides set by this test.
	StageCatalog.load_stages(Paths.STAGES_DIR)
	GameplayRegistry.unregister("test_alias")
	GameplayRegistry.unregister("crane_test")
	RemoteConfig.fetch()


# --- Catalog: shipped ladder ------------------------------------------------------

func test_shipped_ladder_has_five_tap_target_stages() -> void:
	assert_eq(StageCatalog.stage_count(), 5, "shipped ladder has five stages")
	for i in 5:
		var def: StageDefinition = StageCatalog.get_stage(i + 1)
		assert_eq(def.id, i + 1, "stage ids are sequential")
		assert_eq(def.gameplay_key, "tap_target", "shipped stages use the built-in minigame")


func test_shipped_stages_fall_back_to_remote_defaults() -> void:
	var remote_dur := float(RemoteConfig.get_value("round_duration_sec", StageCatalog.DEFAULT_ROUND_DURATION))
	var remote_win := int(RemoteConfig.get_value("win_score", StageCatalog.DEFAULT_WIN_SCORE))
	for i in 5:
		assert_almost_eq(StageCatalog.effective_duration(i + 1), remote_dur, 0.001, "stage %d duration falls back to remote" % (i + 1))
		assert_eq(StageCatalog.effective_win_score(i + 1), remote_win, "stage %d win score falls back to remote" % (i + 1))


func test_get_stage_clamps_to_ladder_bounds() -> void:
	assert_eq(StageCatalog.get_stage(99).id, StageCatalog.stage_count(), "huge ids clamp to the last stage")
	assert_eq(StageCatalog.get_stage(-5).id, 1, "negative ids clamp to the first stage")


# --- Catalog: custom ladders via the temp dir -------------------------------------

func test_custom_stage_values_override_remote_defaults() -> void:
	_write_stage("t2_a.tres", 1, "", "tap_target", 10.0, 99)
	_write_stage("t2_b.tres", 2)
	var count := StageCatalog.load_stages(TEMP_STAGE_DIR)
	assert_eq(count, 2, "temp ladder loads exactly the two written stages")
	assert_almost_eq(StageCatalog.effective_duration(1), 10.0, 0.001, "own duration wins over remote")
	assert_eq(StageCatalog.effective_win_score(1), 99, "own win score wins over remote")
	var remote_dur := float(RemoteConfig.get_value("round_duration_sec", StageCatalog.DEFAULT_ROUND_DURATION))
	var remote_win := int(RemoteConfig.get_value("win_score", StageCatalog.DEFAULT_WIN_SCORE))
	assert_almost_eq(StageCatalog.effective_duration(2), remote_dur, 0.001, "zero duration falls back to remote")
	assert_eq(StageCatalog.effective_win_score(2), remote_win, "zero win score falls back to remote")


func test_missing_stage_dir_warns_and_falls_back() -> void:
	var count := StageCatalog.load_stages("user://gut_tmp/no_such_stage_dir/")
	assert_push_warning("no stages found", "missing dir warns")
	assert_eq(count, 5, "fallback ladder has five stages")
	for i in 5:
		assert_eq(StageCatalog.get_stage(i + 1).gameplay_key, "tap_target", "fallback stages are tap-target")


# --- GameplayRegistry ---------------------------------------------------------------

func test_registry_creates_registered_gameplay() -> void:
	var gameplay := GameplayRegistry.create("tap_target")
	assert_true(gameplay is TapTargetGameplay, "built-in key creates the tap-target widget")
	gameplay.free()


func test_registry_unknown_key_warns_and_falls_back() -> void:
	var gameplay := GameplayRegistry.create("plinko_does_not_exist")
	assert_push_warning("unknown gameplay key", "unknown key warns")
	assert_true(gameplay is TapTargetGameplay, "unknown key falls back to the built-in minigame")
	gameplay.free()


func test_registry_register_unregister_roundtrip() -> void:
	GameplayRegistry.register("test_alias", TapTargetGameplay)
	assert_true(GameplayRegistry.has("test_alias"), "register adds the key")
	var gameplay := GameplayRegistry.create("test_alias")
	assert_true(gameplay is TapTargetGameplay, "registered key creates its widget")
	gameplay.free()
	GameplayRegistry.unregister("test_alias")
	assert_false(GameplayRegistry.has("test_alias"), "unregister removes the key")


# --- GameScreen wiring ----------------------------------------------------------------

func test_game_screen_uses_stage_data_and_advances_on_win() -> void:
	SaveSystem.set_value("profile", "stage", 2)
	RemoteConfig.set_value("win_score", 0)
	_write_stage("t6_a.tres", 1)
	_write_stage("t6_b.tres", 2, "", "tap_target", 0.2, 0)
	_write_stage("t6_c.tres", 3)
	StageCatalog.load_stages(TEMP_STAGE_DIR)
	EventBus.gameplay_started.connect(_on_gameplay_started_spy)
	var screen := _mount(GameScreen.new())
	EventBus.gameplay_started.disconnect(_on_gameplay_started_spy)
	assert_eq(int(_started_context.get("stage", -1)), 2, "round starts at the saved stage")
	assert_almost_eq(float(_started_context.get("duration_sec", -1.0)), 0.2, 0.001, "round duration comes from the stage definition")
	assert_true(_started_context.has("gameplay"), "start context carries the gameplay key")
	assert_eq(str(_started_context.get("gameplay", "")), "tap_target", "no override means the stage's own key")
	assert_almost_eq(screen._round_duration_sec, 0.2, 0.001, "screen stores the effective duration")
	assert_true(screen._gameplay is TapTargetGameplay, "stage-selected widget is created")
	screen._on_round_ended(0)
	assert_eq(int(SaveSystem.get_value("profile", "stage", -1)), 3, "winning (score >= effective win_score) advances the stage")


func test_remote_override_forces_gameplay_key() -> void:
	RemoteConfig.set_value("gameplay_scene", "crane_test")
	var screen := _mount(GameScreen.new())
	assert_push_warning("unknown gameplay key", "unregistered override key warns")
	assert_true(screen._gameplay is TapTargetGameplay, "override falls back to a playable widget")
	GameplayRegistry.register("crane_test", TapTargetGameplay)
	var screen2 := _mount(GameScreen.new())
	assert_eq(screen2._effective_gameplay_key(1), "crane_test", "registered override key is selected for every stage")


# --- Home ladder -----------------------------------------------------------------------

func test_home_ladder_renders_catalog_with_name_keys() -> void:
	SaveSystem.set_value("meta", "ftue_done", true)
	_write_stage("t8_a.tres", 1)
	_write_stage("t8_b.tres", 2, "stage_alpha")
	_write_stage("t8_c.tres", 3)
	StageCatalog.load_stages(TEMP_STAGE_DIR)
	var screen := _mount(HomeScreen.new())
	await _settle_layout()
	assert_eq(screen._stage_labels.size(), 3, "ladder renders one row per catalog stage")
	assert_eq(screen._stage_labels[1].text, "stage_alpha", "name_key is tr()-resolved for its label")
	assert_eq(screen._stage_labels[0].text, tr("home_stage") % [1], "stages without a name_key use the generic label")
	SaveSystem.set_value("profile", "stage", 2)
	screen._refresh()
	assert_true(screen._stage_buttons[1].visible, "current stage shows PLAY")
	assert_false(screen._stage_locked[0].visible, "cleared stages show no lock")
	assert_true(screen._stage_locked[2].visible, "later stages are locked")


# --- Helpers ---------------------------------------------------------------------------

func _write_stage(file_name: String, id: int, name_key: String = "", gameplay_key: String = "tap_target", duration_sec: float = 0.0, win_score: int = 0) -> void:
	var def := StageDefinition.new()
	def.id = id
	def.name_key = name_key
	def.gameplay_key = gameplay_key
	def.duration_sec = duration_sec
	def.win_score = win_score
	ResourceSaver.save(def, TEMP_STAGE_DIR + file_name)


func _wipe_stage_dir() -> void:
	var dir := DirAccess.open(TEMP_STAGE_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(TEMP_STAGE_DIR + file_name)
		file_name = dir.get_next()


func _mount(screen: BaseScreen) -> BaseScreen:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


func _settle_layout(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame


func _on_gameplay_started_spy(context: Dictionary) -> void:
	_started_context = context
