extends SceneTree
## H3 visual verification (NOT part of the hermetic gate — needs a real
## renderer): renders TeamBannerView layers through the LUT shader in a
## SubViewport, reads the pixels back and classifies them against the palette.
## Proves the remap window spreads the art's flat luminance across multiple
## palette indices (before H3 every recipe rendered as ONE bright hue near the
## right end of the ramp).
##
## Run: xvfb-run -a ~/tools/godot --path . -s res://tools/verify_banner_lut.gd

const VIEW_SIZE := Vector2i(256, 512)
const TOLERANCE := 0.08
const WARMUP_FRAMES := 30


func _initialize() -> void:
	var vp := SubViewport.new()
	vp.size = VIEW_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Keep per-pixel alpha in the readback so transparent sprite pixels (icon
	# cutout) are skipped instead of being classified as black-background.
	vp.transparent_bg = true
	root.add_child(vp)

	# 1) Base alone: the bright field and the dark frame must land on DIFFERENT
	# palette indices (a duotone, not one flat hue).
	var base_hist := await _render_and_classify(vp, {"base": "base_15", "base_lut": "lut_01"}, "lut_01")
	# 2) Icon alone: the icon's shading must span >=3 distinct indices (the
	# multi-color case that was broken).
	var icon_hist := await _render_and_classify(vp, {"icon": "icon_01", "icon_lut": "lut_02"}, "lut_02")

	var base_ok := base_hist.size() >= 2
	var icon_ok := icon_hist.size() >= 3
	print("verify_banner_lut: base_15+lut_01 indices=%s (need >=2, field vs frame) %s" % [str(base_hist), "PASS" if base_ok else "FAIL"])
	print("verify_banner_lut: icon_01+lut_02 indices=%s (need >=3, shading spread) %s" % [str(icon_hist), "PASS" if icon_ok else "FAIL"])
	quit(0 if base_ok and icon_ok else 1)


func _render_and_classify(vp: SubViewport, recipe: Dictionary, lut_id: String) -> Dictionary:
	var view := TeamBannerView.new()
	view.size = Vector2(VIEW_SIZE)
	vp.add_child(view)
	view.setup(recipe)
	for i in WARMUP_FRAMES:
		await process_frame
	var img: Image = vp.get_texture().get_image()
	var entry: Dictionary = TeamBannerCatalog.find_lut(lut_id)
	var colors: Array = entry.get("colors", [])
	var hist := {}
	var y := 0
	while y < img.get_height():
		var x := 0
		while x < img.get_width():
			var px: Color = img.get_pixel(x, y)
			if px.a >= 0.5:
				for i in colors.size():
					var c: Color = colors[i]
					if _close(px, c):
						hist[i] = int(hist.get(i, 0)) + 1
						break
			x += 2
		y += 2
	view.queue_free()
	await process_frame
	return hist


func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= TOLERANCE and absf(a.g - b.g) <= TOLERANCE and absf(a.b - b.b) <= TOLERANCE
