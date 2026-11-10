class_name ProtoIcon
extends Control
## Icon with a texture-first, code-drawn fallback (ART_MANIFEST.md, G2). Each
## key resolves to assets/sprites/icons/<key>.png (generated placeholder art;
## real art later drops onto the same paths = zero code changes). When the
## file is missing the icon falls back to the original geometric figure built
## from the ThemeFactory palette, so a deleted asset degrades gracefully.

const ICONS_DIR: String = "res://assets/sprites/icons/"
const DEFAULT_SIZE: float = 32.0

var _key: String = ""
var _tint: Color = Color()
var _texture: Texture2D = null


func setup(key: String, icon_size: float = DEFAULT_SIZE, tint: Color = Color()) -> void:
	_key = key
	_tint = tint
	custom_minimum_size = Vector2(icon_size, icon_size)
	_reload_texture()
	queue_redraw()


## Re-points the icon at another key without resizing.
func set_icon(key: String) -> void:
	_key = key
	_reload_texture()
	queue_redraw()


## Loads the canonical texture for the current key (null when absent). A tint
## rides on modulate ONLY while the texture path is active — the code-drawn
## fallback applies its tint per-shape via _col(), so modulate must stay white.
func _reload_texture() -> void:
	_texture = null
	var path := ICONS_DIR + _key + ".png"
	if ResourceLoader.exists(path):
		_texture = load(path) as Texture2D
	modulate = _tint if (_texture != null and _has_tint()) else Color.WHITE


func _draw() -> void:
	if _texture != null:
		draw_texture_rect(_texture, Rect2(Vector2.ZERO, size), false)
		return
	var c := size / 2.0
	var u := size.x * 0.5
	match _key:
		"trophy":
			_draw_trophy(c, u)
		"xp":
			_poly([Vector2(0, -0.9), Vector2(0.22, -0.22), Vector2(0.9, 0), Vector2(0.22, 0.22),
					Vector2(0, 0.9), Vector2(-0.22, 0.22), Vector2(-0.9, 0), Vector2(-0.22, -0.22)], u, _col(ThemeFactory.COLOR_BLUE))
		"coin":
			draw_circle(c, 0.45 * u, _col(ThemeFactory.COLOR_GOLD))
			draw_circle(c, 0.3 * u, _col(ThemeFactory.COLOR_GOLD).darkened(0.35))
		"gem":
			_poly([Vector2(0, -0.85), Vector2(0.6, -0.1), Vector2(0, 0.85), Vector2(-0.6, -0.1)], u, _col(ThemeFactory.COLOR_DIAMOND))
			_line(Vector2(-0.6, -0.1), Vector2(0.6, -0.1), Color.WHITE, c, u)
		"gift":
			_draw_gift(c, u)
		"bank":
			draw_circle(c, 0.45 * u, _col(ThemeFactory.COLOR_TEXT_DIM))
			var slot := Rect2(c.x - 0.18 * u, c.y - 0.32 * u, 0.36 * u, 0.09 * u)
			draw_rect(slot, _col(ThemeFactory.COLOR_INK))
		"booster":
			_poly([Vector2(0, -0.8), Vector2(0.55, 0), Vector2(0, 0.8), Vector2(-0.55, 0)], u, _col(ThemeFactory.COLOR_BLUE))
			_line(Vector2(-0.18, 0), Vector2(0.18, 0), Color.WHITE, c, u)
			_line(Vector2(0, -0.18), Vector2(0, 0.18), Color.WHITE, c, u)
		"crown":
			_poly([Vector2(-0.7, 0.4), Vector2(-0.7, -0.3), Vector2(-0.35, 0.0), Vector2(0, -0.55),
					Vector2(0.35, 0.0), Vector2(0.7, -0.3), Vector2(0.7, 0.4)], u, _col(ThemeFactory.COLOR_GOLD))
		"chat":
			_draw_chat(c, u)
		"team":
			draw_circle(c + Vector2(-0.25 * u, 0.0), 0.35 * u, _col(ThemeFactory.COLOR_GOLD))
			draw_circle(c + Vector2(0.25 * u, 0.0), 0.35 * u, _col(ThemeFactory.COLOR_BLUE))
		"search":
			var center := c + Vector2(-0.1 * u, -0.1 * u)
			draw_arc(center, 0.4 * u, 0.0, TAU, 24, _col(ThemeFactory.COLOR_TEXT), _stroke(u))
			_line(Vector2(0.18, 0.18), Vector2(0.6, 0.6), _col(ThemeFactory.COLOR_TEXT), c, u)
		"info":
			draw_arc(c, 0.45 * u, 0.0, TAU, 24, _col(ThemeFactory.COLOR_GOLD), _stroke(u))
			draw_circle(Vector2(c.x, c.y - 0.18 * u), 0.07 * u, _col(ThemeFactory.COLOR_GOLD))
			_line(Vector2(0, -0.02), Vector2(0, 0.25), _col(ThemeFactory.COLOR_GOLD), c, u)
		"warning":
			_poly([Vector2(-0.6, 0.45), Vector2(0, -0.55), Vector2(0.6, 0.45)], u, _col(ThemeFactory.COLOR_GOLD))
			_line(Vector2(0, -0.15), Vector2(0, 0.12), ThemeFactory.COLOR_INK, c, u)
			draw_circle(Vector2(c.x, c.y + 0.28 * u), 0.06 * u, ThemeFactory.COLOR_INK)
		"check":
			var pts := PackedVector2Array([Vector2(-0.45, 0.05), Vector2(-0.1, 0.4), Vector2(0.5, -0.35)])
			for i in pts.size():
				pts[i] += c
			draw_polyline(pts, _col(ThemeFactory.COLOR_GREEN), maxf(3.0, u * 0.24))
		"bell":
			draw_circle(Vector2(c.x, c.y - 0.15 * u), 0.38 * u, _col(ThemeFactory.COLOR_GOLD))
			_line(Vector2(-0.45, 0.25), Vector2(0.45, 0.25), _col(ThemeFactory.COLOR_GOLD), c, u)
			draw_circle(Vector2(c.x, c.y + 0.38 * u), 0.09 * u, _col(ThemeFactory.COLOR_GOLD))
			draw_circle(Vector2(c.x, c.y - 0.55 * u), 0.08 * u, _col(ThemeFactory.COLOR_GOLD))
		"music":
			draw_circle(Vector2(c.x - 0.15 * u, c.y + 0.3 * u), 0.2 * u, _col(ThemeFactory.COLOR_BLUE))
			_line(Vector2(0.03, 0.3), Vector2(0.03, -0.45), _col(ThemeFactory.COLOR_BLUE), c, u)
			_poly([Vector2(0.03, -0.45), Vector2(0.45, -0.25), Vector2(0.03, -0.05)], u, _col(ThemeFactory.COLOR_BLUE))
		"sfx":
			_poly([Vector2(-0.5, -0.2), Vector2(-0.15, -0.2), Vector2(0.15, -0.45),
					Vector2(0.15, 0.45), Vector2(-0.15, 0.2), Vector2(-0.5, 0.2)], u, _col(ThemeFactory.COLOR_TEXT))
			draw_arc(Vector2(c.x + 0.2 * u, c.y), 0.3 * u, -0.9, 0.9, 16, _col(ThemeFactory.COLOR_GOLD), _stroke(u))
		"shield":
			_poly([Vector2(0, -0.75), Vector2(0.6, -0.45), Vector2(0.6, 0.1),
					Vector2(0, 0.75), Vector2(-0.6, 0.1), Vector2(-0.6, -0.45)], u, _col(ThemeFactory.COLOR_BLUE))
		"support":
			draw_arc(c, 0.5 * u, 0.0, TAU, 24, _col(ThemeFactory.COLOR_GOLD), maxf(3.0, u * 0.2))
			draw_arc(c, 0.25 * u, 0.0, TAU, 24, _col(ThemeFactory.COLOR_BLUE), maxf(3.0, u * 0.2))
		"pile":
			_draw_pile_box(c + Vector2(-0.32 * u, 0.34 * u), 0.4 * u, _col(ThemeFactory.COLOR_GOLD))
			_draw_pile_box(c + Vector2(0.32 * u, 0.34 * u), 0.4 * u, _col(ThemeFactory.COLOR_GOLD).darkened(0.25))
			_draw_pile_box(c + Vector2(0.0, -0.34 * u), 0.44 * u, _col(ThemeFactory.COLOR_GOLD).lightened(0.15))
		_:
			draw_arc(c, 0.45 * u, 0.0, TAU, 24, _col(ThemeFactory.COLOR_TEXT_DIM), _stroke(u))
			draw_circle(c, 0.1 * u, _col(ThemeFactory.COLOR_TEXT_DIM))


func _draw_trophy(c: Vector2, u: float) -> void:
	var gold := _col(ThemeFactory.COLOR_GOLD)
	_poly([Vector2(-0.35, -0.5), Vector2(0.35, -0.5), Vector2(0.2, 0.05), Vector2(-0.2, 0.05)], u, gold)
	draw_rect(Rect2(c.x - 0.08 * u, c.y + 0.05 * u, 0.16 * u, 0.18 * u), gold)
	draw_rect(Rect2(c.x - 0.25 * u, c.y + 0.23 * u, 0.5 * u, 0.14 * u), gold)


func _draw_gift(c: Vector2, u: float) -> void:
	var gold := _col(ThemeFactory.COLOR_GOLD)
	draw_rect(Rect2(c.x - 0.45 * u, c.y - 0.35 * u, 0.9 * u, 0.8 * u), gold)
	draw_rect(Rect2(c.x - 0.5 * u, c.y - 0.5 * u, 1.0 * u, 0.2 * u), gold.lightened(0.2))
	_line(Vector2(0, -0.5), Vector2(0, 0.45), ThemeFactory.COLOR_INK, c, u)
	_line(Vector2(-0.5, -0.4), Vector2(0.5, -0.4), ThemeFactory.COLOR_INK, c, u)


func _draw_pile_box(center: Vector2, half: float, color: Color) -> void:
	draw_rect(Rect2(center.x - half, center.y - half, half * 2.0, half * 2.0), color)
	draw_line(Vector2(center.x, center.y - half), Vector2(center.x, center.y + half), ThemeFactory.COLOR_INK, maxf(1.5, half * 0.18))


func _draw_chat(c: Vector2, u: float) -> void:
	var blue := _col(ThemeFactory.COLOR_BLUE)
	draw_rect(Rect2(c.x - 0.6 * u, c.y - 0.5 * u, 1.2 * u, 0.8 * u), blue)
	_poly([Vector2(-0.3, 0.3), Vector2(-0.05, 0.3), Vector2(-0.4, 0.6)], u, blue)
	for i in 3:
		draw_circle(Vector2(c.x + (i - 1) * 0.28 * u, c.y - 0.1 * u), 0.06 * u, ThemeFactory.COLOR_INK)


func _poly(points: Array[Vector2], u: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for p in points:
		pts.append(size / 2.0 + p * u)
	draw_colored_polygon(pts, color)


func _line(a: Vector2, b: Vector2, color: Color, c: Vector2, u: float) -> void:
	draw_line(c + a * u, c + b * u, color, _stroke(u))


## Godot 4.7's `Color()` defaults to OPAQUE BLACK (alpha 1.0), not transparent,
## so "no tint" is detected by equality with the sentinel — an alpha check
## would treat every untinted icon as black-tinted.
func _has_tint() -> bool:
	return _tint != Color()


func _col(default_color: Color) -> Color:
	if _has_tint():
		return _tint
	return default_color


func _stroke(u: float) -> float:
	return maxf(2.0, u * 0.16)
