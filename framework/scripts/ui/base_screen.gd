class_name BaseScreen
extends Control
## Base class for every screen (Home, Profile, Social, Settings, Special,
## Game, Results). Guarantees a full-rect layout, a one-time UI build, and
## automatic re-localization when the player switches language mid-session.
##
## Screens are cached and reused by ScreenManager. NOTE (verified against
## 4.7.stable with a tree probe, 2026-11-09): _ready() fires ONLY on the first
## tree entry — re-adding a cached node does NOT re-fire it (NOTIFICATION_
## ENTER_TREE does re-fire). So _build_ui() is guarded here defensively, and
## any screen that must refresh when re-shown has to hook EventBus.screen_
## changed itself (see GiftPileScreen._on_screen_changed, H5).
##
## Subclasses override _build_ui() to construct their UI and _apply_locale()
## to refresh localized text; they do NOT manage the locale_applied
## connection themselves.
##
## LAYOUT CONTRACT: this node is pinned full-rect in _ready(), but its
## CHILDREN are not. The root container created in _build_ui() (usually a
## MarginContainer) MUST be pinned before add_child — e.g.
## set_anchors_preset(Control.PRESET_FULL_RECT) right after construction.
## An unanchored Control shrinks to its minimum size at the top-left corner
## and the screen content will render as a small block in the corner.
##
## GOTCHA (Godot 4.7): never call set_anchors_preset() AFTER the node is in
## the tree (i.e. not in _ready()). It keeps the node's current (zero) rect
## by back-computing negative offsets, permanently locking the control to a
## 0x0 block in the top-left corner. Write anchors/offsets explicitly instead.

var _locale_connected: bool = false
var _ui_built: bool = false


func _ready() -> void:
	# Explicit anchor/offset writes (see GOTCHA above): set_anchors_preset()
	# here would back-compute negative offsets and lock the screen to 0x0.
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	if not _ui_built:
		_build_ui()
		_ui_built = true
	if not LocalizationManager.locale_applied.is_connected(_on_locale_applied):
		LocalizationManager.locale_applied.connect(_on_locale_applied)
		_locale_connected = true
	_apply_locale()


func _exit_tree() -> void:
	if _locale_connected and LocalizationManager.locale_applied.is_connected(_on_locale_applied):
		LocalizationManager.locale_applied.disconnect(_on_locale_applied)
		_locale_connected = false


## Override in subclasses to construct the screen's UI. Called exactly once,
## even if the node re-enters the tree.
func _build_ui() -> void:
	pass


## Override in subclasses to rebuild/refresh localized text.
func _apply_locale() -> void:
	pass


func _on_locale_applied(_language_code: String) -> void:
	_apply_locale()
