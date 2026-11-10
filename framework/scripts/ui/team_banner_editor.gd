class_name TeamBannerEditor
extends Control
## Banner customization UI (TDD §3.19): a live TeamBannerView preview rendered
## at its in-game size (48×96), then four horizontal slider strips — base,
## base palette, icon, icon palette — and an icon-size slider (H7, bounded by
## the view's min/max). Each strip is a horizontally scrolling
## row of radio thumbnail buttons (one ButtonGroup per strip: tapping a new
## option releases the previous one); the editor itself never scrolls
## vertically. Strips scroll by touch-drag because thumbnails use PASS mouse
## filter — a STOP control would swallow the press/motion gestures that
## ScrollContainer's drag-scroll state machine consumes on touch devices.
## Emits recipe_changed(recipe) on every selection; setup(recipe) seeds the
## current selection without emitting. Used by BOTH the create-team dialog and
## the leader settings dialog.

signal recipe_changed(recipe: Dictionary)

const PREVIEW_SIZE: Vector2 = Vector2(48, 96)
const BASE_THUMB: Vector2 = Vector2(40, 80)
const ICON_THUMB: Vector2 = Vector2(64, 64)
const LUT_SWATCH: Vector2 = Vector2(96, 32)
const SEPARATION: int = 8
const THUMB_MARGIN: int = 2

var _recipe: Dictionary = {}
var _setup_pending: bool = false
var _view: TeamBannerView = null
var _base_group := ButtonGroup.new()
var _icon_group := ButtonGroup.new()
var _base_lut_group := ButtonGroup.new()
var _icon_lut_group := ButtonGroup.new()
var _base_buttons: Array[Button] = []
var _icon_buttons: Array[Button] = []
var _base_lut_buttons: Array[Button] = []
var _icon_lut_buttons: Array[Button] = []
var _scale_slider: HSlider = null


func _ready() -> void:
	_build_ui()
	if _setup_pending:
		_apply_selections()
		_update_preview()


## Seeds the current selection (no emit); safe to call before tree entry.
func setup(recipe: Dictionary) -> void:
	_recipe = recipe.duplicate(true) if typeof(recipe) == TYPE_DICTIONARY else {}
	if is_inside_tree():
		_apply_selections()
		_update_preview()
	else:
		_setup_pending = true


func get_recipe() -> Dictionary:
	return _recipe.duplicate(true)


# --- UI -----------------------------------------------------------------------

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	_pin_full_rect(vbox)
	add_child(vbox)
	vbox.add_theme_constant_override("separation", SEPARATION)

	var preview_center := CenterContainer.new()
	preview_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(preview_center)
	_view = TeamBannerView.new()
	_view.custom_minimum_size = PREVIEW_SIZE
	# Fallback chip in a visible neutral tone: the dialog panel behind is
	# COLOR_PANEL, so an empty-recipe preview would otherwise be invisible.
	_view.setup(_recipe.duplicate(true), ThemeFactory.COLOR_TEXT_DIM)
	preview_center.add_child(_view)

	var base_strip := _strip(vbox, tr("banner_base"))
	for i in TeamBannerCatalog.BASE_COUNT:
		var entry: Dictionary = TeamBannerCatalog.bases()[i]
		var button := _thumb_button(load(str(entry.get("path", ""))), BASE_THUMB, _base_group)
		button.toggled.connect(_on_base_selected.bind(i))
		base_strip.add_child(button)
		_base_buttons.append(button)

	var base_lut_strip := _strip(vbox, tr("banner_base_lut"))
	for i in TeamBannerCatalog.LUT_COUNT:
		var entry: Dictionary = TeamBannerCatalog.luts()[i]
		var button := _thumb_button(_lut_swatch_texture(entry.get("colors", [])), LUT_SWATCH, _base_lut_group)
		button.toggled.connect(_on_base_lut_selected.bind(i))
		base_lut_strip.add_child(button)
		_base_lut_buttons.append(button)

	var icon_strip := _strip(vbox, tr("banner_icon"))
	for i in TeamBannerCatalog.ICON_COUNT:
		var entry: Dictionary = TeamBannerCatalog.icons()[i]
		var button := _thumb_button(_icon_thumbnail(load(str(entry.get("path", "")))), ICON_THUMB, _icon_group)
		button.toggled.connect(_on_icon_selected.bind(i))
		icon_strip.add_child(button)
		_icon_buttons.append(button)

	var icon_lut_strip := _strip(vbox, tr("banner_icon_lut"))
	for i in TeamBannerCatalog.LUT_COUNT:
		var entry: Dictionary = TeamBannerCatalog.luts()[i]
		var button := _thumb_button(_lut_swatch_texture(entry.get("colors", [])), LUT_SWATCH, _icon_lut_group)
		button.toggled.connect(_on_icon_lut_selected.bind(i))
		icon_lut_strip.add_child(button)
		_icon_lut_buttons.append(button)

	var scale_box := VBoxContainer.new()
	scale_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_box.add_theme_constant_override("separation", 4)
	var scale_label := Label.new()
	scale_label.text = tr("banner_icon_scale")
	scale_label.theme_type_variation = &"LabelDim"
	scale_box.add_child(scale_label)
	_scale_slider = HSlider.new()
	_scale_slider.min_value = TeamBannerView.ICON_SCALE_MIN
	_scale_slider.max_value = TeamBannerView.ICON_SCALE_MAX
	_scale_slider.step = 0.05
	_scale_slider.value = _clamped_scale(float(_recipe.get("icon_scale", TeamBannerView.DEFAULT_ICON_SCALE)))
	_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scale_slider.value_changed.connect(_on_scale_changed)
	scale_box.add_child(_scale_slider)
	vbox.add_child(scale_box)


## One selection group: a dim section label above a horizontal scroll strip.
## Returns the inner HBox to fill with thumbnails.
func _strip(parent: Control, label_key: String) -> HBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = tr(label_key)
	label.theme_type_variation = &"LabelDim"
	box.add_child(label)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 4)
	scroll.add_child(strip)
	parent.add_child(box)
	return strip


## A thumbnail button with tight content margins (2px): the flat theme's default
## 12px margin would leave zero/negative icon area on a small thumbnail, so the
## icon never draws and the button renders as a blank block. expand_icon then
## stretches the texture to fill the (near-full) button rect. toggle_mode +
## group = radio behavior within one strip. mouse_filter PASS is load-bearing:
## the button still processes taps itself, but press/motion gestures starting on
## a thumbnail also reach the strip's ScrollContainer — which drives its
## drag-scroll state machine from emulated mouse events on touch devices (see
## ScrollContainer.gui_input). With the default STOP filter the strip could only
## be scrolled from the 4px gaps between thumbnails.
func _thumb_button(texture: Texture2D, min_size: Vector2, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_group = group
	button.mouse_filter = Control.MOUSE_FILTER_PASS
	button.icon = texture
	button.expand_icon = true
	button.custom_minimum_size = min_size
	for state in ["normal", "hover"]:
		button.add_theme_stylebox_override(state, _thumb_style(false))
	button.add_theme_stylebox_override("pressed", _thumb_style(true))
	return button


func _thumb_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeFactory.COLOR_GOLD if selected else ThemeFactory.COLOR_PANEL
	sb.set_corner_radius_all(4)
	sb.content_margin_left = THUMB_MARGIN
	sb.content_margin_top = THUMB_MARGIN
	sb.content_margin_right = THUMB_MARGIN
	sb.content_margin_bottom = THUMB_MARGIN
	return sb


## Bakes an icon into a square canvas (centered, aspect preserved) so expand_icon's
## stretch cannot distort non-square heraldry.
func _icon_thumbnail(texture: Texture2D) -> ImageTexture:
	var src := texture.get_image()
	var size := int(ICON_THUMB.x)
	var canvas := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var scale := minf(float(size - 8) / float(src.get_width()), float(size - 8) / float(src.get_height()))
	var w := maxi(1, int(float(src.get_width()) * scale))
	var h := maxi(1, int(float(src.get_height()) * scale))
	var scaled: Image = src.duplicate()
	scaled.resize(w, h, Image.INTERPOLATE_LANCZOS)
	canvas.blit_rect(scaled, Rect2i(0, 0, w, h), Vector2i((size - w) / 2, (size - h) / 2))
	return ImageTexture.create_from_image(canvas)


## A palette swatch: each of the 16 colors as a vertical column (stretched to
## fill the swatch button by expand_icon, so all 16 read clearly).
func _lut_swatch_texture(colors: Array) -> ImageTexture:
	var img := Image.create(32, 16, false, Image.FORMAT_RGB8)
	for x in range(32):
		var color: Color = (colors[x / 2] if x / 2 < colors.size() else Color.WHITE)
		for y in range(16):
			img.set_pixel(x, y, color)
	return ImageTexture.create_from_image(img)


# --- Selection -------------------------------------------------------------------

func _on_base_selected(pressed: bool, index: int) -> void:
	if pressed:
		_select("base", str(TeamBannerCatalog.bases()[index].get("id", "")))


func _on_icon_selected(pressed: bool, index: int) -> void:
	if pressed:
		_select("icon", str(TeamBannerCatalog.icons()[index].get("id", "")))


func _on_base_lut_selected(pressed: bool, index: int) -> void:
	if pressed:
		_select("base_lut", str(TeamBannerCatalog.luts()[index].get("id", "")))


func _on_icon_lut_selected(pressed: bool, index: int) -> void:
	if pressed:
		_select("icon_lut", str(TeamBannerCatalog.luts()[index].get("id", "")))


func _on_scale_changed(value: float) -> void:
	_recipe["icon_scale"] = _clamped_scale(value)
	_update_preview()
	recipe_changed.emit(_recipe.duplicate(true))


## Scale is bounded by the view's min/max (H7): out-of-range recipe values are
## clamped instead of ever reaching rendering.
func _clamped_scale(value: float) -> float:
	return clampf(value, TeamBannerView.ICON_SCALE_MIN, TeamBannerView.ICON_SCALE_MAX)


func _select(key: String, id: String) -> void:
	_recipe[key] = id
	_update_preview()
	recipe_changed.emit(_recipe.duplicate(true))


func _apply_selections() -> void:
	for i in _base_buttons.size():
		_base_buttons[i].set_pressed_no_signal(str(TeamBannerCatalog.bases()[i].get("id", "")) == str(_recipe.get("base", "")))
	for i in _icon_buttons.size():
		_icon_buttons[i].set_pressed_no_signal(str(TeamBannerCatalog.icons()[i].get("id", "")) == str(_recipe.get("icon", "")))
	for i in _base_lut_buttons.size():
		_base_lut_buttons[i].set_pressed_no_signal(str(TeamBannerCatalog.luts()[i].get("id", "")) == str(_recipe.get("base_lut", "")))
	for i in _icon_lut_buttons.size():
		_icon_lut_buttons[i].set_pressed_no_signal(str(TeamBannerCatalog.luts()[i].get("id", "")) == str(_recipe.get("icon_lut", "")))
	if _scale_slider != null:
		_scale_slider.set_value_no_signal(_clamped_scale(float(_recipe.get("icon_scale", TeamBannerView.DEFAULT_ICON_SCALE))))


func _update_preview() -> void:
	_view.setup(_recipe.duplicate(true), ThemeFactory.COLOR_PANEL)


static func _pin_full_rect(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0
