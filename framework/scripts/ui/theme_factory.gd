class_name ThemeFactory
extends RefCounted
## Generates the project's centralized Theme entirely in code.
##
## UI scripts must never hardcode colors, fonts or corner radii — they pull
## everything from this theme (applied to the root Window at boot). The same
## factory is used by tools/build_theme.gd to regenerate
## res://resources/theme/game_theme.tres, so the .tres and the code can never
## drift apart.

const COLOR_BG: Color = Color("#10141f")
const COLOR_PANEL: Color = Color("#1b2233")
const COLOR_GOLD: Color = Color("#f5c542")
const COLOR_BLUE: Color = Color("#4f8cff")
const COLOR_TEXT: Color = Color("#eef2fb")
const COLOR_TEXT_DIM: Color = Color("#9aa7c7")
const COLOR_INK: Color = Color("#10141f")  # text on gold/blue fills
const COLOR_SILVER: Color = Color("#c7cfdd")
const COLOR_DIAMOND: Color = Color("#6fd3f2")
const COLOR_GREEN: Color = Color("#58c470")
const COLOR_ORANGE: Color = Color("#e8973a")

const CORNER_RADIUS: int = 8
const DEFAULT_FONT_SIZE: int = 16
const CONTENT_MARGIN: int = 12
# ButtonNav touch-target padding (H1): the rest state is transparent, so the
# content margin is what keeps these buttons tappable instead of collapsing to
# bare text. Font (16) + 2x14 = 44px minimum height at native resolution.
const NAV_CONTENT_MARGIN: int = 14
# Tab strip padding (H1): tighter than CONTENT_MARGIN — tabs are secondary
# navigation, font (16) + 2x8 = 32px tab height.
const TAB_CONTENT_MARGIN: int = 8

# --- Art stylebox (9-slice) constants -----------------------------------------
# Placeholder art in assets/sprites/ui_generic/. The texture margins below are
# the 9-slice cut positions measured from each artwork (px, natural texture
# size): corner/edge regions that must never stretch. NOTE: content margins
# fall back to these values as the text inset, so art variations are only for
# LARGE controls (a Button gets a 140px label inset per side).

const ART_DIR := "res://assets/sprites/ui_generic/"

const BTN_SLICE_X: float = 140.0
const BTN_SLICE_Y_NORMAL: float = 26.0
const BTN_SLICE_Y_PRESSED: float = 30.0
const DIALOG_TWOTONE_SLICE_X: float = 160.0
const DIALOG_TWOTONE_SLICE_TOP: float = 240.0   # keeps the two-tone header band fixed
const DIALOG_TWOTONE_SLICE_BOTTOM: float = 60.0
const DIALOG_ORANGE_SLICE_X: float = 200.0
const DIALOG_ORANGE_SLICE_TOP: float = 150.0    # covers the top tab nub
const DIALOG_ORANGE_SLICE_BOTTOM: float = 100.0 # thick bottom frame band
const TAB_SLICE_X: float = 60.0
const TAB_SLICE_TOP: float = 90.0               # covers the center tab nub
const TAB_SLICE_BOTTOM: float = 30.0


static func create() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = DEFAULT_FONT_SIZE

	_theme_labels(theme)
	_theme_buttons(theme)
	_theme_panels(theme)
	_theme_progress(theme)
	_theme_line_edits(theme)
	_theme_tab_containers(theme)
	_theme_art_styles(theme)
	_theme_constants(theme)
	return theme


# --- Labels -----------------------------------------------------------------

static func _theme_labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", COLOR_TEXT)

	theme.set_type_variation("LabelDim", "Label")
	theme.set_color("font_color", "LabelDim", COLOR_TEXT_DIM)

	theme.set_type_variation("LabelGold", "Label")
	theme.set_color("font_color", "LabelGold", COLOR_GOLD)
	theme.set_font_size("font_size", "LabelGold", 18)

	theme.set_type_variation("LabelTitle", "Label")
	theme.set_color("font_color", "LabelTitle", COLOR_TEXT)
	theme.set_font_size("font_size", "LabelTitle", 26)
	# Ink variants: jar-art dialogs have a cream body where the light Label /
	# LabelTitle colors would be unreadable.
	theme.set_type_variation("LabelTitleInk", "Label")
	theme.set_color("font_color", "LabelTitleInk", COLOR_INK)
	theme.set_font_size("font_size", "LabelTitleInk", 26)
	theme.set_type_variation("LabelInk", "Label")
	theme.set_color("font_color", "LabelInk", COLOR_INK)


# --- Buttons ----------------------------------------------------------------

static func _theme_buttons(theme: Theme) -> void:
	theme.set_stylebox("normal", "Button", _flat(COLOR_PANEL))
	theme.set_stylebox("hover", "Button", _flat(_brighten(COLOR_PANEL, 0.18)))
	theme.set_stylebox("pressed", "Button", _flat(_darken(COLOR_PANEL, 0.25)))
	theme.set_stylebox("disabled", "Button", _flat(_dim(COLOR_PANEL, 0.6)))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_color", "Button", COLOR_TEXT)
	theme.set_color("font_hover_color", "Button", COLOR_TEXT)
	theme.set_color("font_pressed_color", "Button", COLOR_TEXT)
	theme.set_color("font_disabled_color", "Button", _dim(COLOR_TEXT, 0.5))

	# Primary action (e.g. PLAY): gold fill, dark ink text.
	theme.set_type_variation("ButtonPrimary", "Button")
	theme.set_stylebox("normal", "ButtonPrimary", _flat(COLOR_GOLD))
	theme.set_stylebox("hover", "ButtonPrimary", _flat(_brighten(COLOR_GOLD, 0.18)))
	theme.set_stylebox("pressed", "ButtonPrimary", _flat(_darken(COLOR_GOLD, 0.25)))
	theme.set_stylebox("disabled", "ButtonPrimary", _flat(_dim(COLOR_GOLD, 0.4)))
	theme.set_color("font_color", "ButtonPrimary", COLOR_INK)
	theme.set_color("font_hover_color", "ButtonPrimary", COLOR_INK)
	theme.set_color("font_pressed_color", "ButtonPrimary", COLOR_INK)
	theme.set_color("font_disabled_color", "ButtonPrimary", _dim(COLOR_INK, 0.5))
	theme.set_font_size("font_size", "ButtonPrimary", 20)

	# Secondary action: blue fill.
	theme.set_type_variation("ButtonAccent", "Button")
	theme.set_stylebox("normal", "ButtonAccent", _flat(COLOR_BLUE))
	theme.set_stylebox("hover", "ButtonAccent", _flat(_brighten(COLOR_BLUE, 0.18)))
	theme.set_stylebox("pressed", "ButtonAccent", _flat(_darken(COLOR_BLUE, 0.25)))
	theme.set_stylebox("disabled", "ButtonAccent", _flat(_dim(COLOR_BLUE, 0.4)))
	theme.set_color("font_color", "ButtonAccent", Color.WHITE)
	theme.set_color("font_hover_color", "ButtonAccent", Color.WHITE)
	theme.set_color("font_pressed_color", "ButtonAccent", Color.WHITE)
	theme.set_color("font_disabled_color", "ButtonAccent", _dim(Color.WHITE, 0.5))

	# NavBar toggle buttons: transparent at rest, gold when selected (toggle
	# mode draws the "pressed" stylebox while active). Every state carries the
	# same content margin so the text never shifts between states — and the
	# transparent rest state still yields a real touch target (H1: StyleBoxEmpty
	# collapsed these to bare-text hit areas ~22px tall on phone).
	theme.set_type_variation("ButtonNav", "Button")
	var nav_normal := _flat(Color.TRANSPARENT)
	nav_normal.set_content_margin_all(NAV_CONTENT_MARGIN)
	var nav_hover := _flat(_dim(COLOR_PANEL, 0.5))
	nav_hover.set_content_margin_all(NAV_CONTENT_MARGIN)
	var nav_pressed := _flat(COLOR_GOLD)
	nav_pressed.set_content_margin_all(NAV_CONTENT_MARGIN)
	var nav_disabled := _flat(Color.TRANSPARENT)
	nav_disabled.set_content_margin_all(NAV_CONTENT_MARGIN)
	theme.set_stylebox("normal", "ButtonNav", nav_normal)
	theme.set_stylebox("hover", "ButtonNav", nav_hover)
	theme.set_stylebox("pressed", "ButtonNav", nav_pressed)
	theme.set_stylebox("disabled", "ButtonNav", nav_disabled)
	theme.set_color("font_color", "ButtonNav", COLOR_TEXT_DIM)
	theme.set_color("font_hover_color", "ButtonNav", COLOR_TEXT)
	theme.set_color("font_pressed_color", "ButtonNav", COLOR_INK)


# --- Panels -----------------------------------------------------------------

static func _theme_panels(theme: Theme) -> void:
	var panel := _flat(COLOR_PANEL)
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel)

	# Bordered variant for the Home left/right overlay zones.
	theme.set_type_variation("PanelZone", "Panel")
	var zone := _flat(_dim(COLOR_PANEL, 0.92), Color("#2c3a58"), 1)
	theme.set_stylebox("panel", "PanelZone", zone)

	# Circular variant for the player avatar.
	theme.set_type_variation("PanelAvatar", "Panel")
	var avatar := _flat(COLOR_BLUE, Color.TRANSPARENT, 0, 999)
	theme.set_stylebox("panel", "PanelAvatar", avatar)

	# Compact gold-bordered bubble for long-press tooltips (tighter content
	# margin than the default panel).
	theme.set_type_variation("PanelTooltip", "Panel")
	var tooltip := _flat(_dim(COLOR_PANEL, 0.92), COLOR_GOLD, 1)
	tooltip.set_content_margin_all(8)
	theme.set_stylebox("panel", "PanelTooltip", tooltip)


# --- Progress -----------------------------------------------------------------

static func _theme_progress(theme: Theme) -> void:
	var track := _flat(Color("#0d1119"), Color.TRANSPARENT, 0, 4)
	track.content_margin_left = 0.0
	track.content_margin_right = 0.0
	track.content_margin_top = 0.0
	track.content_margin_bottom = 0.0
	theme.set_stylebox("background", "ProgressBar", track)

	var fill := _flat(COLOR_GOLD, Color.TRANSPARENT, 0, 4)
	fill.content_margin_left = 0.0
	fill.content_margin_right = 0.0
	fill.content_margin_top = 0.0
	fill.content_margin_bottom = 0.0
	theme.set_stylebox("fill", "ProgressBar", fill)
	theme.set_color("font_color", "ProgressBar", COLOR_INK)


# --- Line edits -----------------------------------------------------------------

static func _theme_line_edits(theme: Theme) -> void:
	theme.set_stylebox("normal", "LineEdit", _flat(COLOR_PANEL))
	theme.set_stylebox("focus", "LineEdit", _flat(COLOR_PANEL, COLOR_GOLD, 1))
	theme.set_color("font_color", "LineEdit", COLOR_TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", COLOR_TEXT_DIM)


# --- TabContainer ---------------------------------------------------------------

## Flat dark theme for the BASE TabContainer (H1): Social/Profile tabs fell
## back to the engine's light-grey defaults, clashing with the palette. The art
## variations (TabContainer_*) stay deliberately unwired — the blob tab art
## doesn't fit a tab strip (art review 2026-11-06; pinned by test_ui_skins) —
## so the base type gets a proper flat treatment: dark tab strip, panel-colored
## selected tab with a gold accent line (gold = active, same language as
## ButtonNav's selected state). Item names verified against Godot 4.7's
## TabContainer::_bind_methods (tabbar_background/tab_unselected/…).
static func _theme_tab_containers(theme: Theme) -> void:
	theme.set_stylebox("panel", "TabContainer", _flat(COLOR_PANEL, Color.TRANSPARENT, 0, 0))

	var strip := _flat(COLOR_BG, Color.TRANSPARENT, 0, 0)
	strip.set_content_margin_all(4.0)
	theme.set_stylebox("tabbar_background", "TabContainer", strip)

	var tab_unselected := _flat(_darken(COLOR_PANEL, 0.35), Color.TRANSPARENT, 0, 0)
	tab_unselected.set_content_margin_all(TAB_CONTENT_MARGIN)
	theme.set_stylebox("tab_unselected", "TabContainer", tab_unselected)

	var tab_hovered := _flat(_darken(COLOR_PANEL, 0.15), Color.TRANSPARENT, 0, 0)
	tab_hovered.set_content_margin_all(TAB_CONTENT_MARGIN)
	theme.set_stylebox("tab_hovered", "TabContainer", tab_hovered)
	theme.set_stylebox("tab_focus", "TabContainer", tab_hovered.duplicate())

	var tab_selected := _flat(COLOR_PANEL, Color.TRANSPARENT, 0, 0)
	tab_selected.border_color = COLOR_GOLD
	tab_selected.border_width_top = 2
	tab_selected.set_content_margin_all(TAB_CONTENT_MARGIN)
	theme.set_stylebox("tab_selected", "TabContainer", tab_selected)

	var tab_disabled := _flat(_darken(COLOR_PANEL, 0.5), Color.TRANSPARENT, 0, 0)
	tab_disabled.set_content_margin_all(TAB_CONTENT_MARGIN)
	theme.set_stylebox("tab_disabled", "TabContainer", tab_disabled)

	theme.set_color("font_unselected_color", "TabContainer", COLOR_TEXT_DIM)
	theme.set_color("font_hovered_color", "TabContainer", COLOR_TEXT)
	theme.set_color("font_selected_color", "TabContainer", COLOR_GOLD)
	theme.set_color("font_disabled_color", "TabContainer", _dim(COLOR_TEXT_DIM, 0.5))


# --- Art styleboxes (9-sliced placeholder art) ---------------------------------

## Registers the assets/sprites/ui_generic/ artwork as theme type variations:
## ButtonBlue/Green/Grey/Orange/Red (normal+hover = base, pressed = _Pressed),
## PanelDialog* (Panel "panel" stylebox) and TabContainer* (TabContainer
## "panel" stylebox). "disabled" is left unset on buttons so it inherits the
## flat base Button style.

static func _theme_art_styles(theme: Theme) -> void:
	for name in ["Blue", "Green", "Grey", "Orange", "Red"]:
		var variation: String = "Button" + name
		theme.set_type_variation(variation, "Button")
		var normal := _nine_slice(
			ART_DIR + "Btn_%s.png" % name,
			BTN_SLICE_X, BTN_SLICE_Y_NORMAL, BTN_SLICE_X, BTN_SLICE_Y_NORMAL
		)
		var pressed := _nine_slice(
			ART_DIR + "Btn_%s_Pressed.png" % name,
			BTN_SLICE_X, BTN_SLICE_Y_PRESSED, BTN_SLICE_X, BTN_SLICE_Y_PRESSED
		)
		theme.set_stylebox("normal", variation, normal)
		theme.set_stylebox("hover", variation, normal)
		theme.set_stylebox("pressed", variation, pressed)

	var dialogs: Array = [
		["PanelDialogBlue", "Dialog_Blue_TwoTone.png"],
		["PanelDialogGreen", "Dialog_Green_TwoTone.png"],
		["PanelDialogOrange", "Dialog_Orange.png"],
		["PanelDialogOrangeTwoTone", "Dialog_Orange_TwoTone.png"],
	]
	for entry in dialogs:
		var variation: String = entry[0]
		var file: String = entry[1]
		var is_wide := variation == "PanelDialogOrange"
		var slice_x := DIALOG_ORANGE_SLICE_X if is_wide else DIALOG_TWOTONE_SLICE_X
		var slice_top := DIALOG_ORANGE_SLICE_TOP if is_wide else DIALOG_TWOTONE_SLICE_TOP
		var slice_bottom := DIALOG_ORANGE_SLICE_BOTTOM if is_wide else DIALOG_TWOTONE_SLICE_BOTTOM
		var sb := _nine_slice(ART_DIR + file, slice_x, slice_top, slice_x, slice_bottom)
		# Content margins intentionally left unset: they fall back to the 9-slice
		# cuts, which ARE the art's insets (glass walls / header band). Overriding
		# them would let content draw over the glass. Dialogs stay bounded via
		# DialogHost size hints so the middle stretch stays mild.
		theme.set_type_variation(variation, "Panel")
		theme.set_stylebox("panel", variation, sb)

	for name in ["Blue", "Green", "Orange", "Red"]:
		var variation: String = "TabContainer" + name
		theme.set_type_variation(variation, "TabContainer")
		theme.set_stylebox(
			"panel", variation,
			_nine_slice(ART_DIR + "TabContainer_%s.png" % name, TAB_SLICE_X, TAB_SLICE_TOP, TAB_SLICE_X, TAB_SLICE_BOTTOM)
		)


# --- Layout constants ---------------------------------------------------------

static func _theme_constants(theme: Theme) -> void:
	theme.set_constant("separation", "HBoxContainer", 8)
	theme.set_constant("separation", "VBoxContainer", 8)
	theme.set_constant("outline_size", "Button", 0)


# --- Helpers ------------------------------------------------------------------

static func _flat(
	color: Color,
	border_color: Color = Color.TRANSPARENT,
	border_width: int = 0,
	radius: int = CORNER_RADIUS
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	if border_width > 0:
		sb.border_color = border_color
		sb.set_border_width_all(border_width)
	sb.set_content_margin_all(CONTENT_MARGIN)
	return sb


## Builds a 9-sliced StyleBoxTexture (Godot 4.x's nine-patch stylebox;
## StyleBoxFlat has no texture support). texture_margin_* are the slice cut
## positions in natural texture pixels (axis stretch defaults to STRETCH);
## content margins stay unset and fall back to them, so text is inset by the
## same amounts — these variations are for large controls only.
static func _nine_slice(path: String, left: float, top: float, right: float, bottom: float) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = load(path)
	sb.texture_margin_left = left
	sb.texture_margin_top = top
	sb.texture_margin_right = right
	sb.texture_margin_bottom = bottom
	return sb


static func _brighten(color: Color, amount: float) -> Color:
	return color.lerp(Color.WHITE, amount)


static func _darken(color: Color, amount: float) -> Color:
	return color.lerp(Color.BLACK, amount)


static func _dim(color: Color, opacity: float) -> Color:
	var c := color
	c.a = clampf(opacity, 0.0, 1.0)
	return c
