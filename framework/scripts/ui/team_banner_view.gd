class_name TeamBannerView
extends Control
## Renders a team banner recipe (TDD §3.19): BannerBase full-rect with a
## centered BannerIcon (~40% width × `icon_scale`, clamped to the min/max),
## each layer LUT-colorized through its own ShaderMaterial instance (shared
## shader resource). A layer without a lut id
## renders plain grayscale; an empty recipe renders a flat fallback chip
## (legacy `banner_color` saves / unstyled teams). Used by search rows (small),
## the team header (large) and the banner editor (live preview).

const SHADER_PATH: String = "res://assets/shaders/banner_lut.gdshader"

## Icon scale (H7): multiplier over the default 40%-width / 50%-height rect.
## The range keeps the icon inside the banner at every step (max = 60%×75%).
const ICON_SCALE_MIN: float = 0.5
const ICON_SCALE_MAX: float = 1.5
const DEFAULT_ICON_SCALE: float = 1.0

var _recipe: Dictionary = {}
var _fallback_color: Color = Color.BLACK
var _setup_pending: bool = false
var _shader: Shader = null
var _base_material: ShaderMaterial = null
var _icon_material: ShaderMaterial = null
var _fallback_chip: ColorRect = null
var _base_layer: TextureRect = null
var _icon_layer: TextureRect = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shader = load(SHADER_PATH) as Shader
	_base_material = ShaderMaterial.new()
	_base_material.shader = _shader
	_icon_material = ShaderMaterial.new()
	_icon_material.shader = _shader

	_fallback_chip = ColorRect.new()
	_fallback_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback_chip.visible = false
	_pin_full_rect(_fallback_chip)
	add_child(_fallback_chip)

	_base_layer = TextureRect.new()
	_base_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base_layer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	# The default expand mode makes the MINIMUM size track the texture (256×512
	# bases), which overrides the full-rect anchor pinning and lets the layer
	# overflow its host once a recipe is applied. IGNORE_SIZE keeps sizing with
	# the anchors; stretch_mode still governs the actual draw.
	_base_layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pin_full_rect(_base_layer)
	add_child(_base_layer)

	# Centered ~40% width / 50% height via anchors (no per-frame resize work).
	_icon_layer = TextureRect.new()
	_icon_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_layer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_layer.anchor_left = 0.3
	_icon_layer.anchor_top = 0.25
	_icon_layer.anchor_right = 0.7
	_icon_layer.anchor_bottom = 0.75
	add_child(_icon_layer)

	if _setup_pending:
		_render()


## Seeds the recipe + fallback color; safe to call before tree entry (the
## render happens on ready). Re-call with a new recipe to update in place.
func setup(recipe: Dictionary, fallback_color: Color = Color.BLACK) -> void:
	_recipe = recipe.duplicate(true) if typeof(recipe) == TYPE_DICTIONARY else {}
	_fallback_color = fallback_color
	if is_inside_tree():
		_render()
	else:
		_setup_pending = true


func get_recipe() -> Dictionary:
	return _recipe.duplicate(true)


# --- Internals -------------------------------------------------------------------

func _render() -> void:
	var base_id := str(_recipe.get("base", ""))
	var icon_id := str(_recipe.get("icon", ""))
	if base_id.is_empty() and icon_id.is_empty():
		_fallback_chip.color = _fallback_color
		_fallback_chip.visible = true
		_base_layer.visible = false
		_icon_layer.visible = false
		return
	_fallback_chip.visible = false
	_apply_icon_scale()
	if base_id.is_empty():
		_base_layer.visible = false
	else:
		var entry := TeamBannerCatalog.find_base(base_id)
		_base_layer.texture = load(str(entry.get("path", "")))
		_apply_lut(_base_layer, _base_material, str(_recipe.get("base_lut", "")))
		_base_layer.visible = true
	if icon_id.is_empty():
		_icon_layer.visible = false
	else:
		var entry := TeamBannerCatalog.find_icon(icon_id)
		_icon_layer.texture = load(str(entry.get("path", "")))
		_apply_lut(_icon_layer, _icon_material, str(_recipe.get("icon_lut", "")))
		_icon_layer.visible = true


## Re-derives the icon layer's centered anchors from the recipe `icon_scale`
## (H7): a uniform multiplier over the default 0.4×0.5 rect, clamped to the
## min/max so the icon never overflows the banner. The anchor box keeps its
## aspect under uniform scaling, so the layout never distorts.
func _apply_icon_scale() -> void:
	var scale := clampf(float(_recipe.get("icon_scale", DEFAULT_ICON_SCALE)), ICON_SCALE_MIN, ICON_SCALE_MAX)
	var w := 0.4 * scale
	var h := 0.5 * scale
	_icon_layer.anchor_left = 0.5 - w / 2.0
	_icon_layer.anchor_top = 0.5 - h / 2.0
	_icon_layer.anchor_right = 0.5 + w / 2.0
	_icon_layer.anchor_bottom = 0.5 + h / 2.0


## Layer + lut id -> its own ShaderMaterial with the palette texture; an empty
## lut id renders the layer plain grayscale (material cleared).
func _apply_lut(layer: TextureRect, material: ShaderMaterial, lut_id: String) -> void:
	if lut_id.is_empty():
		layer.material = null
		return
	material.set_shader_parameter("lut_tex", TeamBannerCatalog.get_lut_texture(lut_id))
	layer.material = material


static func _pin_full_rect(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0
