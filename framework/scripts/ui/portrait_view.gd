class_name PortraitView
extends Control
## Composite player portrait: crown on top, flair around the icon (ring /
## banner / capsule) and the portrait icon in the center. Reads the same
## profile-style keys used by the save "profile" domain:
## portrait_icon / portrait_flair / portrait_crown (+ "name" for initials).
##
## Call setup(size) before adding to the tree, then apply_profile(dict).

const PROFILE_KEY_ICON: String = "portrait_icon"
const PROFILE_KEY_FLAIR: String = "portrait_flair"
const PROFILE_KEY_CROWN: String = "portrait_crown"
const CROWN_ROW_RATIO: float = 0.32
const RING_BORDER_WIDTH: int = 3

var _size: float = 64.0
var _crown_row: CenterContainer = null
var _crown_icon: ProtoIcon = null
var _flair_panel: Panel = null
var _avatar: Panel = null
var _initials: Label = null
# G2 texture layers (ART_MANIFEST.md): canonical portrait textures when present,
# the code-drawn paths above stay as the fallback when a file is missing.
var _icon_tex_rect: TextureRect = null
var _flair_tex_rect: TextureRect = null
var _crown_tex_rect: TextureRect = null


func setup(host_size: float) -> void:
	_size = host_size
	custom_minimum_size = Vector2(host_size, host_size * (1.0 + CROWN_ROW_RATIO))
	_build()


## Re-renders the portrait from a profile-style dictionary.
func apply_profile(profile: Dictionary) -> void:
	var icon_entry: Dictionary = PortraitCatalog.find_icon(str(profile.get(PROFILE_KEY_ICON, "")))
	var flair_entry: Dictionary = PortraitCatalog.find_flair(str(profile.get(PROFILE_KEY_FLAIR, "")))
	var crown_entry: Dictionary = PortraitCatalog.find_crown(str(profile.get(PROFILE_KEY_CROWN, "")))

	var player_name: String = str(profile.get("name", ""))
	_initials.text = player_name.substr(0, 1).to_upper() if player_name != "" else "?"

	_reload_textures(icon_entry, flair_entry, crown_entry)

	# The avatar's flat color is only the fallback backing; when the canonical
	# icon texture is present it carries its own circular shape.
	if _icon_tex_rect.visible:
		_avatar.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	else:
		var avatar_style := StyleBoxFlat.new()
		avatar_style.bg_color = icon_entry["color"]
		avatar_style.set_corner_radius_all(999)
		if str(flair_entry.get("type", "none")) == "ring":
			avatar_style.border_color = flair_entry["color"]
			avatar_style.set_border_width_all(RING_BORDER_WIDTH)
		_avatar.add_theme_stylebox_override("panel", avatar_style)

	_apply_flair_panel(flair_entry)
	_apply_crown(crown_entry)


## Resolves the canonical textures for the current entries (G2). Missing files
## keep the code-drawn fallbacks — a deleted asset degrades gracefully.
func _reload_textures(icon_entry: Dictionary, flair_entry: Dictionary, crown_entry: Dictionary) -> void:
	_icon_tex_rect.texture = _load_tex(PortraitCatalog.icon_texture_path(str(icon_entry.get("id", ""))))
	_icon_tex_rect.visible = _icon_tex_rect.texture != null
	_flair_tex_rect.texture = _load_tex(PortraitCatalog.flair_texture_path(str(flair_entry.get("id", "none"))))
	_flair_tex_rect.visible = _flair_tex_rect.texture != null
	_crown_tex_rect.texture = _load_tex(PortraitCatalog.crown_texture_path(str(crown_entry.get("id", "none"))))
	_crown_tex_rect.visible = _crown_tex_rect.texture != null


func _load_tex(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res: Variant = load(path)
	return res as Texture2D if res != null else null


func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	_crown_row = CenterContainer.new()
	_crown_row.custom_minimum_size = Vector2(0, _size * CROWN_ROW_RATIO)
	root.add_child(_crown_row)
	_crown_icon = ProtoIcon.new()
	_crown_row.add_child(_crown_icon)
	_crown_tex_rect = _texture_layer(Vector2(_size * 0.42, _size * 0.42))
	_crown_row.add_child(_crown_tex_rect)

	var icon_area := Control.new()
	icon_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(icon_area)

	var area_center := CenterContainer.new()
	area_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_area.add_child(area_center)

	var icon_box := Control.new()
	icon_box.custom_minimum_size = Vector2(_size, _size)
	area_center.add_child(icon_box)

	_flair_tex_rect = _texture_layer(Vector2(_size, _size))
	icon_box.add_child(_flair_tex_rect)

	_flair_panel = Panel.new()
	_flair_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_box.add_child(_flair_panel)

	var avatar_center := CenterContainer.new()
	avatar_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_box.add_child(avatar_center)

	_avatar = Panel.new()
	_avatar.custom_minimum_size = Vector2(_size, _size)
	avatar_center.add_child(_avatar)

	_icon_tex_rect = _texture_layer(Vector2(_size, _size))
	_avatar.add_child(_icon_tex_rect)

	_initials = Label.new()
	_initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_initials.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar.add_child(_initials)


## Texture layer for the G2 canonical art: hidden until a texture is assigned,
## IGNORE so it never intercepts input.
func _texture_layer(min_size: Vector2) -> TextureRect:
	var tex := TextureRect.new()
	tex.custom_minimum_size = min_size
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.visible = false
	return tex


func _apply_flair_panel(flair_entry: Dictionary) -> void:
	if _flair_tex_rect.visible:
		_flair_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		return
	var ftype := str(flair_entry.get("type", "none"))
	match ftype:
		"banner":
			# Horizontal band across the middle, behind the avatar.
			_flair_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			_flair_panel.anchor_top = 0.42
			_flair_panel.anchor_bottom = 0.58
			var sb := StyleBoxFlat.new()
			sb.bg_color = flair_entry["color"]
			sb.set_corner_radius_all(4)
			_flair_panel.add_theme_stylebox_override("panel", sb)
		"capsule":
			# Pill outline hugging the avatar.
			_flair_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			var inset := -float(RING_BORDER_WIDTH)
			_flair_panel.offset_left = inset
			_flair_panel.offset_top = inset
			_flair_panel.offset_right = -inset
			_flair_panel.offset_bottom = -inset
			var sb := StyleBoxFlat.new()
			sb.set_corner_radius_all(999)
			sb.border_color = flair_entry["color"]
			sb.set_border_width_all(RING_BORDER_WIDTH)
			_flair_panel.add_theme_stylebox_override("panel", sb)
		_:
			# Ring flairs live on the avatar border itself; nothing here.
			_flair_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			_flair_panel.offset_left = 0.0
			_flair_panel.offset_top = 0.0
			_flair_panel.offset_right = 0.0
			_flair_panel.offset_bottom = 0.0
			_flair_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())


func _apply_crown(crown_entry: Dictionary) -> void:
	if _crown_tex_rect.visible:
		_crown_icon.visible = false
		return
	var icon_key := str(crown_entry.get("icon", ""))
	if icon_key == "":
		_crown_icon.visible = false
	else:
		_crown_icon.setup(icon_key, _size * 0.42, crown_entry["color"])
		_crown_icon.visible = true


func _circular_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(999)
	return sb
