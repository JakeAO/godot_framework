extends SceneTree
## OBSOLETE — DO NOT RUN (2026-11-06): the placeholder art it generates was
## replaced by real sheet-split artwork at the SAME paths. Running this tool
## would overwrite base_01..36 / icon_01..36 with generated patterns and
## destroy the real art. Kept only as a record of how the placeholders were
## made (TDD §3.19). The real-art pipeline is tools/split_banner_sheets.py.
##
## One-shot tool: generates the grayscale placeholder team-banner art (TDD
## §3.19) — 36 base backdrops (512x256, L8) from six pattern families x six
## variants, and 36 icon glyphs (256x256, RGBA8) from twelve shapes rasterized
## by an even-odd scanline fill x three scales. The ids are pinned by
## TeamBannerCatalog. NOTE: -s SceneTree scripts run without autoloads
## (build_stages discipline).
##
## Run: godot --headless --path . -s res://tools/generate_team_banners.gd

const BASES_DIR := "res://assets/sprites/team_banners/bases/"
const ICONS_DIR := "res://assets/sprites/team_banners/icons/"
const BASE_W: int = 512
const BASE_H: int = 256
const ICON_SIZE: int = 256
const BASE_COUNT: int = 36
const ICON_COUNT: int = 36
const BASE_VARIANTS: int = 6


func _initialize() -> void:
	if DirAccess.open(BASES_DIR) == null and DirAccess.make_dir_recursive_absolute(BASES_DIR) != OK:
		push_error("generate_team_banners: could not create %s" % BASES_DIR)
		quit(1)
		return
	if DirAccess.open(ICONS_DIR) == null and DirAccess.make_dir_recursive_absolute(ICONS_DIR) != OK:
		push_error("generate_team_banners: could not create %s" % ICONS_DIR)
		quit(1)
		return
	for i in range(BASE_COUNT):
		_save_base(i)
	for i in range(ICON_COUNT):
		_save_icon(i)
	print("Generated %d bases + %d icons under res://assets/sprites/team_banners/" % [BASE_COUNT, ICON_COUNT])
	quit(0)


# --- Bases (grayscale pattern backdrops) ----------------------------------------

func _save_base(index: int) -> void:
	var family := index / BASE_VARIANTS
	var v := float(index % BASE_VARIANTS)
	var img := Image.create(BASE_W, BASE_H, false, Image.FORMAT_L8)
	for y in range(BASE_H):
		for x in range(BASE_W):
			img.set_pixel(x, y, Color(_base_value(family, v, float(x), float(y)), 0.0, 0.0, 1.0))
	var path := "%sbase_%02d.png" % [BASES_DIR, index + 1]
	if img.save_png(path) != OK:
		push_error("generate_team_banners: failed to save %s" % path)


func _base_value(family: int, v: float, x: float, y: float) -> float:
	match family:
		0:  # vertical stripes
			var t := fposmod(x * (0.02 + v * 0.012), 1.0)
			return 0.8 if t < 0.5 else 0.3
		1:  # diagonal stripes
			var d := fposmod((x + y) * (0.016 + v * 0.008), 1.0)
			return 0.78 if d < 0.45 else 0.28
		2:  # chevrons
			var c := absf(fposmod((x / float(BASE_W) + y / float(BASE_H)) * (3.0 + v), 1.0) - 0.5)
			return 0.8 if c < 0.14 else 0.32
		3:  # waves
			var w := sin(y * (0.16 + v * 0.1) + sin(x * (0.04 + v * 0.02)) * 2.4)
			return 0.55 + 0.3 * w
		4:  # checker
			var cw := 96.0 - v * 12.0
			var cell := int(x / cw) + int(y / cw)
			return 0.78 if cell % 2 == 0 else 0.3
		5:  # radial rings (center, then corner for the later variants)
			var origin := Vector2(BASE_W * 0.5, BASE_H * 0.5) if v < 3.0 else Vector2(0.0, 0.0)
			var r := Vector2(x, y).distance_to(origin)
			var t := fposmod(r * (0.06 + v * 0.015), 1.0)
			return 0.78 if t < 0.5 else 0.3
	return 0.5


# --- Icons (filled glyphs, even-odd scanline fill) --------------------------------

func _save_icon(index: int) -> void:
	var shape_index := index / 3
	var scales := [0.62, 0.78, 0.94]
	var img := Image.create(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	_fill_even_odd(img, _glyph_polys(shape_index), float(scales[index % 3]))
	var path := "%sicon_%02d.png" % [ICONS_DIR, index + 1]
	if img.save_png(path) != OK:
		push_error("generate_team_banners: failed to save %s" % path)


## Unit-space polygons per glyph (12 shapes). Multi-polygon entries use the
## even-odd rule for differences (crescent, ring).
func _glyph_polys(shape_index: int) -> Array:
	match shape_index:
		0:  # star
			return [_star(5, 0.48, 0.2)]
		1:  # bolt
			return [[Vector2(0.6, 0.0), Vector2(0.2, 0.55), Vector2(0.45, 0.55), Vector2(0.35, 1.0), Vector2(0.8, 0.4), Vector2(0.5, 0.4)]]
		2:  # shield
			return [[Vector2(0.5, 0.02), Vector2(0.9, 0.15), Vector2(0.9, 0.5), Vector2(0.5, 0.98), Vector2(0.1, 0.5), Vector2(0.1, 0.15)]]
		3:  # crown
			return [[Vector2(0.08, 0.9), Vector2(0.08, 0.45), Vector2(0.28, 0.62), Vector2(0.5, 0.3), Vector2(0.72, 0.62), Vector2(0.92, 0.45), Vector2(0.92, 0.9)]]
		4:  # flame (teardrop)
			return [[Vector2(0.5, 0.0), Vector2(0.78, 0.45), Vector2(0.72, 0.78), Vector2(0.5, 0.95), Vector2(0.28, 0.78), Vector2(0.22, 0.45)]]
		5:  # heart
			return [[Vector2(0.5, 0.95), Vector2(0.08, 0.55), Vector2(0.1, 0.25), Vector2(0.3, 0.1), Vector2(0.5, 0.3), Vector2(0.7, 0.1), Vector2(0.9, 0.25), Vector2(0.92, 0.55)]]
		6:  # diamond
			return [[Vector2(0.5, 0.02), Vector2(0.88, 0.4), Vector2(0.5, 0.98), Vector2(0.12, 0.4)]]
		7:  # arrow (up block)
			return [[Vector2(0.5, 0.0), Vector2(0.9, 0.45), Vector2(0.65, 0.45), Vector2(0.65, 0.95), Vector2(0.35, 0.95), Vector2(0.35, 0.45)]]
		8:  # hexagon
			return [_star(6, 0.47, 0.47)]
		9:  # cross (plus)
			return [[Vector2(0.38, 0.05), Vector2(0.62, 0.05), Vector2(0.62, 0.38), Vector2(0.95, 0.38), Vector2(0.95, 0.62), Vector2(0.62, 0.62), Vector2(0.62, 0.95), Vector2(0.38, 0.95), Vector2(0.38, 0.62), Vector2(0.05, 0.62), Vector2(0.05, 0.38), Vector2(0.38, 0.38)]]
		10:  # crescent (outer circle minus offset circle)
			return [_circle(Vector2(0.5, 0.5), 0.45), _circle(Vector2(0.68, 0.42), 0.38)]
		11:  # ring (concentric circles)
			return [_circle(Vector2(0.5, 0.5), 0.45), _circle(Vector2(0.5, 0.5), 0.22)]
	return [[Vector2(0.5, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]]


func _star(sides: int, outer: float, inner: float) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	for i in sides * 2:
		var angle := -PI / 2.0 + TAU * float(i) / float(sides * 2)
		var r := outer if i % 2 == 0 else inner
		pts.append(Vector2(0.5 + cos(angle) * r, 0.5 + sin(angle) * r))
	return pts


func _circle(center: Vector2, radius: float) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	for i in 24:
		var angle := TAU * float(i) / 24.0
		pts.append(Vector2(center.x + cos(angle) * radius, center.y + sin(angle) * radius))
	return pts


func _fill_even_odd(img: Image, polys: Array, scale: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var size := float(mini(w, h)) * scale
	for y in range(h):
		var yc := (float(y) + 0.5) / float(h)
		var xs: Array[float] = []
		for poly in polys:
			var pts: Array = poly
			for i in pts.size():
				var a := _to_px(pts[i] as Vector2, w, h, size)
				var b := _to_px(pts[(i + 1) % pts.size()] as Vector2, w, h, size)
				if (a.y < yc) != (b.y < yc):
					xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		for s in range(0, xs.size() - 1, 2):
			var x_start := maxi(int(ceil(xs[s] - 0.5)), 0)
			var x_end := mini(int(floor(xs[s + 1] - 0.5)) + 1, w)
			for x in range(x_start, x_end):
				img.set_pixel(x, y, Color.WHITE)


func _to_px(p: Vector2, w: int, h: int, size: float) -> Vector2:
	return Vector2(float(w) * 0.5 + (p.x - 0.5) * size, float(h) * 0.5 + (p.y - 0.5) * size)
