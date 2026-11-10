class_name UISkins
extends RefCounted
## Single swap point for the art skins in assets/sprites/ui_generic/ (the
## 9-slice theme type variations registered by ThemeFactory._theme_art_styles).
## Screens never reference raw variation names — they read a role constant from
## here, so re-skinning is a one-line change per role. tests/test_ui_skins.gd
## pins every role to a variation that is actually registered in the generated
## theme, so this map can never drift from it.
##
## Only DIALOG_PANEL is wired today (2026-11-06 art review): the button and
## tab-container artworks are blob silhouettes (ovals / folder tabs) that 9-slice
## badly onto our wide-short buttons and full-screen portrait tab containers, so
## those controls use the flat theme. The variations stay registered in the theme
## (pinned by test_ui_art_styles.gd) for future use at sizes that fit them.

const DIALOG_PANEL: StringName = &"PanelDialogBlue"
