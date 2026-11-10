extends GutTest
## OfferSpriteWidget: sprite-art offer widgets for the Home side zones (Daily
## Gift, Piggy Bank). Both SpriteFrames resources must load with idle/opening
## clips; the widget scales the art to fit its host square, loops the idle clip
## ambiently, and play_opening() runs the one-shot opening clip before
## returning to looping idle. Also covers ScreenShell's icon-key routing:
## "gift"/"bank" offers get animated widgets, everything else a ProtoIcon.

const GIFT_FRAMES: String = "res://assets/sprites/gift_sprite_individual_frames/gift.tres"
const PIGGYBANK_FRAMES: String = "res://assets/sprites/piggybank_individual_frames/piggybank.tres"
const WIDGET_SIZE: float = 56.0

var _host: Control
var _widgets: Array[OfferSpriteWidget] = []


func before_all() -> void:
	_host = Control.new()
	_host.size = Vector2(400, 400)
	add_child(_host)


func after_each() -> void:
	for widget in _widgets:
		if is_instance_valid(widget):
			widget.queue_free()
	_widgets.clear()


func after_all() -> void:
	if is_instance_valid(_host):
		_host.queue_free()


# --- SpriteFrames resources -----------------------------------------------------

func test_gift_frames_have_idle_and_opening_clips() -> void:
	var frames: SpriteFrames = load(GIFT_FRAMES)
	assert_not_null(frames, "gift.tres loads")
	var anims := frames.get_animation_names()
	assert_true(anims.has(&"idle"), "idle clip present")
	assert_true(anims.has(&"opening"), "opening clip present")
	assert_eq(frames.get_frame_count(&"idle"), 6, "idle clip has 6 frames")
	assert_eq(frames.get_frame_count(&"opening"), 7, "opening clip has 7 frames")


func test_piggybank_frames_have_idle_and_opening_clips() -> void:
	var frames: SpriteFrames = load(PIGGYBANK_FRAMES)
	assert_not_null(frames, "piggybank.tres loads")
	var anims := frames.get_animation_names()
	assert_true(anims.has(&"idle"), "idle clip present")
	assert_true(anims.has(&"opening"), "opening clip present")
	assert_eq(frames.get_frame_count(&"idle"), 6, "idle clip has 6 frames")
	assert_eq(frames.get_frame_count(&"opening"), 7, "opening clip has 7 frames")


# --- Widget behavior ------------------------------------------------------------

func test_setup_builds_a_sprite_fitted_to_the_host() -> void:
	var widget := _make_widget(GIFT_FRAMES)
	assert_not_null(widget._sprite, "AnimatedSprite2D built")
	assert_eq(widget.custom_minimum_size, Vector2(WIDGET_SIZE, WIDGET_SIZE), "fixed host square")
	var frames: SpriteFrames = load(GIFT_FRAMES)
	var max_side := _largest_frame_side(frames)
	assert_gt(max_side, 0.0, "frames have a measurable size")
	assert_almost_eq(widget._sprite.scale.x, WIDGET_SIZE / max_side, 0.001, "scaled against the largest frame side so no frame overflows")


func test_idle_clip_plays_looped_and_advances() -> void:
	var widget := _make_widget(GIFT_FRAMES)
	await _settle(3)
	var frames: SpriteFrames = load(GIFT_FRAMES)
	assert_eq(widget._sprite.animation, &"idle", "idle clip playing after setup")
	assert_true(frames.get_animation_loop(&"idle"), "idle clip loops")
	var ticks := 0
	while widget._sprite.get_frame() == 0 and ticks < 120:
		await get_tree().process_frame
		ticks += 1
	assert_gt(widget._sprite.get_frame(), 0, "idle clip advances its frames")


func test_play_opening_runs_one_shot_then_returns_to_idle() -> void:
	var widget := _make_widget(PIGGYBANK_FRAMES)
	await _settle(3)
	var frames: SpriteFrames = load(PIGGYBANK_FRAMES)
	widget.play_opening()
	assert_eq(widget._sprite.animation, &"opening", "opening clip starts")
	assert_false(frames.get_animation_loop(&"opening"), "opening forced one-shot while playing")
	var ticks := 0
	while widget._sprite.animation != &"idle" and ticks < 600:
		await get_tree().process_frame
		ticks += 1
	assert_eq(widget._sprite.animation, &"idle", "returns to idle after the opening finishes")
	assert_true(frames.get_animation_loop(&"opening"), "looping restored on the opening clip after it finishes")


func test_play_opening_without_setup_is_safe() -> void:
	var widget := OfferSpriteWidget.new()
	_host.add_child(widget)
	_widgets.append(widget)
	widget.play_opening()
	assert_true(true, "play_opening() before setup() does not crash")


# --- ScreenShell routing ----------------------------------------------------------

func test_shell_routes_gift_and_bank_offers_to_sprite_widgets() -> void:
	var shell := ScreenShell.new()
	_host.add_child(shell)
	var items := VBoxContainer.new()
	shell.add_child(items)
	var gift := shell._add_widget(items, "gift")
	assert_true((gift["icon"] as Control) is OfferSpriteWidget, "'gift' offer gets an animated sprite widget")
	var bank := shell._add_widget(items, "bank")
	assert_true((bank["icon"] as Control) is OfferSpriteWidget, "'bank' offer gets an animated sprite widget")
	var booster := shell._add_widget(items, "booster")
	assert_true((booster["icon"] as Control) is ProtoIcon, "other offers fall back to a code-drawn ProtoIcon")
	shell.queue_free()


# --- Helpers --------------------------------------------------------------------

func _make_widget(frames_path: String) -> OfferSpriteWidget:
	var widget := OfferSpriteWidget.new()
	_host.add_child(widget)
	widget.setup(frames_path, WIDGET_SIZE)
	_widgets.append(widget)
	return widget


## Mirrors the widget's fit logic: scale must keep every frame inside the host.
func _largest_frame_side(frames: SpriteFrames) -> float:
	var max_side := 0.0
	for anim_name in frames.get_animation_names():
		for j in frames.get_frame_count(anim_name):
			var frame: Texture2D = frames.get_frame_texture(anim_name, j)
			max_side = maxf(max_side, maxf(frame.get_size().x, frame.get_size().y))
	return max_side


func _settle(frames: int = 3) -> void:
	for i in frames:
		await get_tree().process_frame
