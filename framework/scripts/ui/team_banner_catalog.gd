class_name TeamBannerCatalog
extends RefCounted
## Team banner options (TDD §3.19): grayscale base/icon sprites under
## assets/sprites/team_banners/ + 16-color LUT palettes as data. The ids are
## what gets persisted in the `team` domain's recipe keys. The art on disk is
## real sheet-split artwork (tools/split_banner_sheets.py); a future art pass
## swaps files at the SAME paths — catalog + shader unchanged (ProtoIcon
## doctrine). Lookup by id warns and falls back to the first entry, so an
## unknown id never bricks rendering.

const BASES_DIR: String = "res://assets/sprites/team_banners/bases/"
const ICONS_DIR: String = "res://assets/sprites/team_banners/icons/"
const LUT_COLORS: int = 16
const LUT_STYLES: int = 4
const BASE_COUNT: int = 90
const ICON_COUNT: int = 90
const LUT_COUNT: int = 48

static var _bases: Array[Dictionary] = []
static var _icons: Array[Dictionary] = []
static var _luts: Array[Dictionary] = []
static var _lut_textures: Dictionary = {}  # lut id -> ImageTexture (runtime-built)


## All base entries: {id, path}.
static func bases() -> Array[Dictionary]:
	_ensure_built()
	return _bases


## All icon entries: {id, path}.
static func icons() -> Array[Dictionary]:
	_ensure_built()
	return _icons


## All palette entries: {id, colors: Array[Color]} (LUT_COLORS each).
static func luts() -> Array[Dictionary]:
	_ensure_built()
	return _luts


static func find_base(id: String) -> Dictionary:
	_ensure_built()
	for entry in _bases:
		if str(entry.get("id", "")) == id:
			return entry
	push_warning("TeamBannerCatalog: unknown base id '%s'; using the first base" % id)
	return _bases[0]


static func find_icon(id: String) -> Dictionary:
	_ensure_built()
	for entry in _icons:
		if str(entry.get("id", "")) == id:
			return entry
	push_warning("TeamBannerCatalog: unknown icon id '%s'; using the first icon" % id)
	return _icons[0]


static func find_lut(id: String) -> Dictionary:
	_ensure_built()
	for entry in _luts:
		if str(entry.get("id", "")) == id:
			return entry
	push_warning("TeamBannerCatalog: unknown lut id '%s'; using the first palette" % id)
	return _luts[0]


## The 16x1 ImageTexture for a palette, built at runtime from its Color array
## and cached by lut id (no palette PNGs on disk). Unknown ids resolve through
## find_lut's warn + fallback.
static func get_lut_texture(lut_id: String) -> ImageTexture:
	var entry := find_lut(lut_id)
	var resolved := str(entry.get("id", ""))
	if _lut_textures.has(resolved):
		return _lut_textures[resolved] as ImageTexture
	var colors: Array = entry.get("colors", [])
	var img := Image.create(LUT_COLORS, 1, false, Image.FORMAT_RGB8)
	for i in range(LUT_COLORS):
		img.set_pixel(i, 0, (colors[i] if i < colors.size() else Color.WHITE))
	var tex := ImageTexture.create_from_image(img)
	_lut_textures[resolved] = tex
	return tex


# --- Internals -------------------------------------------------------------------

static func _ensure_built() -> void:
	if not _bases.is_empty():
		return
	for i in range(1, BASE_COUNT + 1):
		_bases.append({"id": "base_%02d" % i, "path": "%sbase_%02d.png" % [BASES_DIR, i]})
	for i in range(1, ICON_COUNT + 1):
		_icons.append({"id": "icon_%02d" % i, "path": "%sicon_%02d.png" % [ICONS_DIR, i]})
	for i in range(LUT_COUNT):
		_luts.append({"id": "lut_%02d" % (i + 1), "colors": _lut_colors(i)})


## 48 palettes = 12 hue families x 4 styles (ramp / vivid / muted / duotone).
static func _lut_colors(index: int) -> Array[Color]:
	var family := index / LUT_STYLES
	var style := index % LUT_STYLES
	var base_hue := float(family) * (360.0 / float(LUT_COUNT / LUT_STYLES))
	var colors: Array[Color] = []
	for i in range(LUT_COLORS):
		var t := float(i) / float(LUT_COLORS - 1)
		match style:
			0:
				colors.append(Color.from_hsv(fmod(base_hue + t * 12.0, 360.0) / 360.0, 0.85, lerp(0.22, 1.0, t)))
			1:
				colors.append(Color.from_hsv(fmod(base_hue - t * 18.0 + 360.0, 360.0) / 360.0, 1.0, lerp(0.55, 1.0, t)))
			2:
				colors.append(Color.from_hsv(base_hue / 360.0, 0.45, lerp(0.35, 0.8, t)))
			3:
				var dark := Color.from_hsv(base_hue / 360.0, 0.9, 0.25)
				var light := Color.from_hsv(fmod(base_hue + 180.0, 360.0) / 360.0, 0.8, 1.0)
				colors.append(dark.lerp(light, t))
	return colors
