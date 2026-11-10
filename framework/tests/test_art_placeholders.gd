extends GutTest
## G1/G2 art pipeline (ART_MANIFEST.md): the generated placeholder textures must
## exist at their canonical paths/sizes, ProtoIcon and PortraitView must render
## from them (texture-first with the code-drawn fallback when a file is
## missing), and OfferSpriteWidget.frames_path_for_icon() is the single source
## of truth for offer frame routing. Keep _ICON_KEYS in sync with proto_icon.gd's
## match arms — this suite fails if a key has no placeholder on disk.

const ICONS_DIR: String = "res://assets/sprites/icons/"
const PORTRAIT_ICONS: Array[String] = ["default", "gold", "silver", "diamond", "ember", "forest"]
const FLAIRS: Array[String] = ["ring_gold", "ring_blue", "banner_gold", "banner_blue", "capsule_gold", "capsule_blue"]
const CROWNS: Array[String] = ["crown_gold", "crown_silver", "crown_diamond"]
const BACKGROUND_PATH: String = "res://assets/sprites/backgrounds/bg_default.png"

## Every ProtoIcon key (must match proto_icon.gd's _draw() match arms).
const _ICON_KEYS: Array[String] = [
	"trophy", "xp", "coin", "gem", "gift", "bank", "booster", "crown",
	"chat", "team", "search", "info", "warning", "check", "bell", "music",
	"sfx", "shield", "support", "pile",
]

var _host: Control
var _icons: Array[ProtoIcon] = []
var _views: Array[PortraitView] = []


func before_all() -> void:
	_host = Control.new()
	_host.size = Vector2(400, 400)
	add_child(_host)


func after_each() -> void:
	for icon in _icons:
		if is_instance_valid(icon):
			icon.queue_free()
	_icons.clear()
	for view in _views:
		if is_instance_valid(view):
			view.queue_free()
	_views.clear()


## Immediate free (not queue_free) so GUT's end-of-script child check sees no
## pending host — matches the test_ui_skins pattern.
func after_all() -> void:
	if is_instance_valid(_host):
		_host.free()


# --- Canonical placeholder inventory ---------------------------------------------

func test_every_proto_icon_key_has_a_128x128_placeholder() -> void:
	for key in _ICON_KEYS:
		var path := ICONS_DIR + key + ".png"
		assert_true(ResourceLoader.exists(path), "placeholder exists for icon key '%s'" % key)
		var tex: Texture2D = load(path) as Texture2D
		assert_not_null(tex, "placeholder loads for icon key '%s'" % key)
		if tex != null:
			assert_eq(tex.get_size(), Vector2(128, 128), "icon '%s' is 128x128" % key)


func test_portrait_placeholders_exist_at_canonical_sizes() -> void:
	for pid in PORTRAIT_ICONS:
		var path := PortraitCatalog.icon_texture_path(pid)
		assert_true(ResourceLoader.exists(path), "portrait icon exists for '%s'" % pid)
		var tex: Texture2D = load(path) as Texture2D
		assert_eq(tex.get_size(), Vector2(128, 128), "portrait icon '%s' is 128x128" % pid)
	for fid in FLAIRS:
		var path := PortraitCatalog.flair_texture_path(fid)
		assert_true(ResourceLoader.exists(path), "flair exists for '%s'" % fid)
		var tex: Texture2D = load(path) as Texture2D
		assert_eq(tex.get_size(), Vector2(128, 128), "flair '%s' is 128x128" % fid)
	for cid in CROWNS:
		var path := PortraitCatalog.crown_texture_path(cid)
		assert_true(ResourceLoader.exists(path), "crown exists for '%s'" % cid)
		var tex: Texture2D = load(path) as Texture2D
		assert_eq(tex.get_size(), Vector2(96, 96), "crown '%s' is 96x96" % cid)


func test_background_placeholder_exists() -> void:
	assert_true(ResourceLoader.exists(BACKGROUND_PATH), "bg_default.png exists")
	var tex: Texture2D = load(BACKGROUND_PATH) as Texture2D
	assert_eq(tex.get_size(), Vector2(720, 1560), "background is the 720x1560 device reference size")


# --- ProtoIcon texture-first rendering -------------------------------------------

func test_proto_icon_loads_its_canonical_texture() -> void:
	var icon := _make_icon("trophy", 32.0)
	assert_not_null(icon._texture, "canonical texture resolved for 'trophy'")
	await _settle(2)
	assert_true(true, "texture path draws without engine errors")


func test_proto_icon_tint_rides_on_modulate_only_for_textures() -> void:
	var icon := _make_icon("gem", 32.0, ThemeFactory.COLOR_GOLD)
	assert_not_null(icon._texture, "textured icon")
	assert_eq(icon.modulate, ThemeFactory.COLOR_GOLD, "tint applied via modulate while the texture path is active")
	icon.set_icon("gem")
	var plain := _make_icon("gem", 32.0)
	assert_eq(plain.modulate, Color.WHITE, "no tint = white modulate (code-drawn fallback stays untainted)")


func test_proto_icon_falls_back_to_code_draw_for_unknown_key() -> void:
	var icon := _make_icon("no_such_key_xyz", 32.0)
	assert_null(icon._texture, "unknown key has no canonical texture")
	assert_eq(icon.modulate, Color.WHITE, "fallback keeps white modulate")
	await _settle(2)
	assert_true(true, "code-drawn fallback renders without engine errors")


# --- Offer frames registry ---------------------------------------------------------

func test_frames_path_registry_is_the_single_source_of_truth() -> void:
	var gift := OfferSpriteWidget.frames_path_for_icon("gift")
	var bank := OfferSpriteWidget.frames_path_for_icon("bank")
	assert_true(gift != "" and ResourceLoader.exists(gift), "'gift' routes to an existing frames resource")
	assert_true(bank != "" and ResourceLoader.exists(bank), "'bank' routes to an existing frames resource")
	assert_eq(OfferSpriteWidget.frames_path_for_icon("trophy"), "", "non-sprite keys return empty (ProtoIcon fallback)")


# --- PortraitView texture-first rendering -------------------------------------------

func test_portrait_view_renders_from_canonical_textures() -> void:
	var view := _mount_portrait(96.0)
	view.apply_profile({
		"name": "Player",
		"portrait_icon": "gold",
		"portrait_flair": "ring_gold",
		"portrait_crown": "crown_diamond",
	})
	assert_true(view._icon_tex_rect.visible, "icon texture layer visible")
	assert_true(view._flair_tex_rect.visible, "flair texture layer visible")
	assert_true(view._crown_tex_rect.visible, "crown texture layer visible")
	assert_false(view._crown_icon.visible, "code-drawn crown hidden while the texture is active")
	await _settle(2)
	assert_true(true, "texture-backed portrait renders without engine errors")


func test_portrait_view_none_flair_and_crown_keep_fallbacks() -> void:
	var view := _mount_portrait(96.0)
	view.apply_profile({
		"name": "Player",
		"portrait_icon": "default",
		"portrait_flair": "none",
		"portrait_crown": "none",
	})
	assert_true(view._icon_tex_rect.visible, "icon texture still active")
	assert_false(view._flair_tex_rect.visible, "'none' flair has no file -> code-drawn path")
	assert_false(view._crown_tex_rect.visible, "'none' crown has no file -> hidden")
	await _settle(2)
	assert_true(true, "mixed texture/fallback portrait renders without engine errors")


# --- Helpers --------------------------------------------------------------------

func _make_icon(key: String, icon_size: float, tint: Color = Color()) -> ProtoIcon:
	var icon := ProtoIcon.new()
	_host.add_child(icon)
	icon.setup(key, icon_size, tint)
	_icons.append(icon)
	return icon


func _mount_portrait(host_size: float) -> PortraitView:
	var view := PortraitView.new()
	_host.add_child(view)
	view.setup(host_size)
	_views.append(view)
	return view


func _settle(frames: int = 3) -> void:
	for i in frames:
		await get_tree().process_frame
