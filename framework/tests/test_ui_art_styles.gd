extends GutTest
## Theme art stylebox catalog (assets/sprites/ui_generic/): every 9-slice
## variation registered by ThemeFactory must exist in the generated
## game_theme.tres with the measured texture margins and the right texture,
## so the .tres can never silently drift from the art assets. Also pins the
## base TabContainer flat theme (H1) against the engine's light-grey defaults.

const THEME_PATH := "res://resources/theme/game_theme.tres"

# [variation, stylebox_name, texture_file, width, height, l, t, r, b]
const CATALOG: Array = [
	["ButtonBlue", "normal", "Btn_Blue.png", 512, 253, 140.0, 26.0, 140.0, 26.0],
	["ButtonBlue", "pressed", "Btn_Blue_Pressed.png", 512, 259, 140.0, 30.0, 140.0, 30.0],
	["ButtonGreen", "normal", "Btn_Green.png", 512, 253, 140.0, 26.0, 140.0, 26.0],
	["ButtonGreen", "pressed", "Btn_Green_Pressed.png", 512, 259, 140.0, 30.0, 140.0, 30.0],
	["ButtonGrey", "normal", "Btn_Grey.png", 512, 253, 140.0, 26.0, 140.0, 26.0],
	["ButtonGrey", "pressed", "Btn_Grey_Pressed.png", 512, 259, 140.0, 30.0, 140.0, 30.0],
	["ButtonOrange", "normal", "Btn_Orange.png", 512, 253, 140.0, 26.0, 140.0, 26.0],
	["ButtonOrange", "pressed", "Btn_Orange_Pressed.png", 512, 259, 140.0, 30.0, 140.0, 30.0],
	["ButtonRed", "normal", "Btn_Red.png", 512, 253, 140.0, 26.0, 140.0, 26.0],
	["ButtonRed", "pressed", "Btn_Red_Pressed.png", 512, 259, 140.0, 30.0, 140.0, 30.0],
	["PanelDialogBlue", "panel", "Dialog_Blue_TwoTone.png", 992, 1056, 160.0, 240.0, 160.0, 60.0],
	["PanelDialogGreen", "panel", "Dialog_Green_TwoTone.png", 992, 1056, 160.0, 240.0, 160.0, 60.0],
	["PanelDialogOrange", "panel", "Dialog_Orange.png", 1120, 960, 200.0, 150.0, 200.0, 100.0],
	["PanelDialogOrangeTwoTone", "panel", "Dialog_Orange_TwoTone.png", 992, 1056, 160.0, 240.0, 160.0, 60.0],
	["TabContainerBlue", "panel", "TabContainer_Blue.png", 710, 360, 60.0, 90.0, 60.0, 30.0],
	["TabContainerGreen", "panel", "TabContainer_Green.png", 710, 360, 60.0, 90.0, 60.0, 30.0],
	["TabContainerOrange", "panel", "TabContainer_Orange.png", 710, 360, 60.0, 90.0, 60.0, 30.0],
	["TabContainerRed", "panel", "TabContainer_Red.png", 710, 360, 60.0, 90.0, 60.0, 30.0],
]

var _theme: Theme


func before_all() -> void:
	_theme = load(THEME_PATH) as Theme


func test_theme_loads_with_art_variations() -> void:
	assert_not_null(_theme, "game_theme.tres loads")
	if _theme == null:
		return
	for row in CATALOG:
		var variation: String = row[0]
		var sb: StyleBoxTexture = _theme.get_stylebox(row[1], variation) as StyleBoxTexture
		assert_not_null(sb, "%s/%s stylebox registered" % [variation, row[1]])
	for entry in [["Button", "Blue"], ["Button", "Green"], ["Button", "Grey"], ["Button", "Orange"], ["Button", "Red"],
			["Panel", "DialogBlue"], ["Panel", "DialogGreen"], ["Panel", "DialogOrange"], ["Panel", "DialogOrangeTwoTone"],
			["TabContainer", "Blue"], ["TabContainer", "Green"], ["TabContainer", "Orange"], ["TabContainer", "Red"]]:
		var base: String = entry[0]
		var variation: String = base + entry[1]
		assert_true(_theme.get_type_variation_list(base).has(variation), "%s registered as a %s variation" % [variation, base])


func test_texture_margins_and_sizes_match_catalog() -> void:
	if _theme == null:
		return
	for row in CATALOG:
		var variation: String = row[0]
		var style: String = row[1]
		var sb: StyleBoxTexture = _theme.get_stylebox(style, variation) as StyleBoxTexture
		if sb == null:
			continue
		assert_true(sb is StyleBoxTexture, "%s/%s is a 9-slice StyleBoxTexture" % [variation, style])
		var texture: Texture2D = sb.texture
		assert_not_null(texture, "%s/%s has a texture" % [variation, style])
		if texture == null:
			continue
		assert_eq(String(texture.get_path()).get_file(), row[2], "%s/%s texture file" % [variation, style])
		assert_eq(texture.get_size(), Vector2(row[3], row[4]), "%s/%s natural size" % [variation, style])
		assert_eq(sb.texture_margin_left, row[5], "%s/%s left cut" % [variation, style])
		assert_eq(sb.texture_margin_top, row[6], "%s/%s top cut" % [variation, style])
		assert_eq(sb.texture_margin_right, row[7], "%s/%s right cut" % [variation, style])
		assert_eq(sb.texture_margin_bottom, row[8], "%s/%s bottom cut" % [variation, style])


func test_button_states_share_normal_and_fall_back_for_disabled() -> void:
	if _theme == null:
		return
	for color in ["Blue", "Green", "Grey", "Orange", "Red"]:
		var variation: String = "Button" + color
		var normal: StyleBoxTexture = _theme.get_stylebox("normal", variation) as StyleBoxTexture
		var hover: StyleBoxTexture = _theme.get_stylebox("hover", variation) as StyleBoxTexture
		var pressed: StyleBoxTexture = _theme.get_stylebox("pressed", variation) as StyleBoxTexture
		assert_true(normal == hover, "%s hover reuses the normal stylebox" % variation)
		assert_true(pressed != normal, "%s pressed is its own stylebox" % variation)
		# Intentionally unset on the art variations: get_stylebox resolves the
		# inheritance chain (returning a copy), so assert the resolved result
		# is the flat base Button style rather than an art texture box.
		var disabled: StyleBox = _theme.get_stylebox("disabled", variation)
		assert_true(disabled is StyleBoxFlat, "%s disabled resolves to the flat base Button style" % variation)


func test_art_variations_render_without_errors() -> void:
	if _theme == null:
		return
	# Mounting real controls with the art variations exercises the 9-slice draw
	# path; any engine error pushed during the frames below fails this test.
	var host := Control.new()
	add_child(host)
	var btn := Button.new()
	btn.theme_type_variation = &"ButtonBlue"
	btn.custom_minimum_size = Vector2(600, 253)
	host.add_child(btn)
	var panel := Panel.new()
	panel.theme_type_variation = &"PanelDialogOrange"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(panel)
	var tabs := TabContainer.new()
	tabs.theme_type_variation = &"TabContainerRed"
	tabs.custom_minimum_size = Vector2(710, 360)
	host.add_child(tabs)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(btn.is_inside_tree(), "art button mounted")
	assert_true(panel.is_inside_tree(), "art dialog panel mounted")
	assert_true(tabs.is_inside_tree(), "art tab container mounted")
	host.queue_free()
	await get_tree().process_frame


func test_base_tab_container_theme_is_flat_dark() -> void:
	if _theme == null:
		return
	# H1: the base TabContainer must not fall back to the engine's light-grey
	# defaults — every state is a flat dark stylebox with a gold select accent.
	for name in ["panel", "tabbar_background", "tab_unselected", "tab_hovered",
			"tab_selected", "tab_disabled", "tab_focus"]:
		var sb: StyleBox = _theme.get_stylebox(name, "TabContainer")
		assert_not_null(sb, "base TabContainer %s stylebox registered" % name)
		if sb == null:
			continue
		assert_true(sb is StyleBoxFlat, "base TabContainer %s is flat (no engine grey)" % name)

	var strip := _theme.get_stylebox("tabbar_background", "TabContainer") as StyleBoxFlat
	_assert_color(strip.bg_color, ThemeFactory.COLOR_BG, "tab bar strip bg")
	assert_eq(strip.content_margin_left, 4.0, "tab bar strip padding")

	var unselected := _theme.get_stylebox("tab_unselected", "TabContainer") as StyleBoxFlat
	_assert_color(unselected.bg_color, ThemeFactory.COLOR_PANEL.lerp(Color.BLACK, 0.35), "unselected tab bg")
	assert_eq(unselected.content_margin_left, float(ThemeFactory.TAB_CONTENT_MARGIN), "unselected tab padding")

	var hovered := _theme.get_stylebox("tab_hovered", "TabContainer") as StyleBoxFlat
	_assert_color(hovered.bg_color, ThemeFactory.COLOR_PANEL.lerp(Color.BLACK, 0.15), "hovered tab bg")

	var focus := _theme.get_stylebox("tab_focus", "TabContainer") as StyleBoxFlat
	_assert_color(focus.bg_color, hovered.bg_color, "focus matches hover")

	var selected := _theme.get_stylebox("tab_selected", "TabContainer") as StyleBoxFlat
	_assert_color(selected.bg_color, ThemeFactory.COLOR_PANEL, "selected tab bg")
	assert_eq(selected.border_width_top, 2, "selected tab gold top border width")
	_assert_color(selected.border_color, ThemeFactory.COLOR_GOLD, "selected tab border color")

	var disabled := _theme.get_stylebox("tab_disabled", "TabContainer") as StyleBoxFlat
	_assert_color(disabled.bg_color, ThemeFactory.COLOR_PANEL.lerp(Color.BLACK, 0.5), "disabled tab bg")

	_assert_color(_theme.get_color("font_unselected_color", "TabContainer"), ThemeFactory.COLOR_TEXT_DIM, "unselected tab font")
	_assert_color(_theme.get_color("font_hovered_color", "TabContainer"), ThemeFactory.COLOR_TEXT, "hovered tab font")
	_assert_color(_theme.get_color("font_selected_color", "TabContainer"), ThemeFactory.COLOR_GOLD, "selected tab font")
	var disabled_font := _theme.get_color("font_disabled_color", "TabContainer")
	_assert_color(Color(disabled_font.r, disabled_font.g, disabled_font.b), ThemeFactory.COLOR_TEXT_DIM, "disabled tab font rgb")
	assert_almost_eq(disabled_font.a, 0.5, 0.001, "disabled tab font alpha")


func _assert_color(actual: Color, expected: Color, label: String) -> void:
	# The .tres serializes colors at 6 decimal places, so compare components
	# with tolerance instead of exact equality.
	assert_almost_eq(actual.r, expected.r, 0.001, label + " r")
	assert_almost_eq(actual.g, expected.g, 0.001, label + " g")
	assert_almost_eq(actual.b, expected.b, 0.001, label + " b")
