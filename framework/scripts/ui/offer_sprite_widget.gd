class_name OfferSpriteWidget
extends Control
## Animated offer widget for Home-side-zone offers that have sprite art
## (Piggy Bank, Daily Gift). Hosts an AnimatedSprite2D scaled to fit a fixed
## square: the looping "idle" clip plays ambiently, and play_opening() runs
## the one-shot "opening" clip for claim feedback before returning to idle.


const IDLE_ANIM: StringName = &"idle"
const OPENING_ANIM: StringName = &"opening"

## Canonical icon key -> sprite frames .tres map (ART_MANIFEST.md, G2). This is
## the ONLY place offer frame paths live; callers route through it so a new
## sprite-art offer is one line here. "" = no sprite frames for this key
## (callers fall back to ProtoIcon).
static func frames_path_for_icon(icon_key: String) -> String:
	match icon_key:
		"gift":
			return "res://assets/sprites/gift_sprite_individual_frames/gift.tres"
		"bank":
			return "res://assets/sprites/piggybank_individual_frames/piggybank.tres"
	return ""

var _sprite: AnimatedSprite2D = null


func setup(frames_path: String, host_size: float) -> void:
	custom_minimum_size = Vector2(host_size, host_size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frames: SpriteFrames = load(frames_path)
	if frames == null:
		push_error("OfferSpriteWidget: failed to load sprite frames '%s'" % frames_path)
		return
	_sprite = AnimatedSprite2D.new()
	_sprite.sprite_frames = frames
	# AnimatedSprite2D is a Node2D, not a Control: it never takes GUI input.
	_sprite.centered = true
	var max_side := _largest_frame_side(frames)
	if max_side > 0.0:
		_sprite.scale = Vector2.ONE * (host_size / max_side)
	add_child(_sprite)
	_sprite.position = custom_minimum_size / 2.0
	_sprite.play(IDLE_ANIM)


## Plays the "opening" clip once, then returns to the looping idle clip. The
## optional `on_finished` callback fires after the return to idle (used by the
## zone dialogs to close themselves once the clip has played).
func play_opening(on_finished: Callable = Callable()) -> void:
	if _sprite == null or not is_inside_tree():
		return
	var frames := _sprite.sprite_frames
	if frames == null:
		return
	# "opening" is authored as a looping clip; force one-shot so we can return.
	frames.set_animation_loop(OPENING_ANIM, false)
	_sprite.animation_finished.connect(_on_opening_finished.bind(on_finished), CONNECT_ONE_SHOT)
	_sprite.play(OPENING_ANIM)


func _on_opening_finished(on_finished: Callable) -> void:
	if _sprite != null and _sprite.sprite_frames != null:
		_sprite.sprite_frames.set_animation_loop(OPENING_ANIM, true)
		_sprite.play(IDLE_ANIM)
	if on_finished.is_valid():
		on_finished.call()


## Frames vary slightly in size within a clip; scale against the largest side
## so no frame overflows the host square.
func _largest_frame_side(frames: SpriteFrames) -> float:
	var max_side := 0.0
	for anim_name in frames.get_animation_names():
		for j in frames.get_frame_count(anim_name):
			var frame: Texture2D = frames.get_frame_texture(anim_name, j)
			max_side = maxf(max_side, maxf(frame.get_size().x, frame.get_size().y))
	return max_side
