extends Node
## Autoload "UIManager". Global overlay services for everything that opens on
## top of a screen without being a screen itself:
##   - Dialogs: near-full-screen windows (legal pages, support, detail views)
##   - Tooltips: long-press hints — opt-in per control (attach_tooltip), a
##     small icon+text bubble above the held element; any other interaction
##     dismisses it
##   - Toasts: transient top banners with queueing, tap-to-act and state
##     filtering so they never pop at inopportune moments
##   - Tutorial/FTUE: dimmed highlight + arrow that only clears when the
##     player interacts with the highlighted element
##
## Hosts live on a high CanvasLayer so they float above every screen,
## including fullscreen ones. Z-order (bottom to top): dialogs, tooltips,
## toasts, tutorial.

const LAYER: int = 10

var dialog_host: DialogHost
var tooltip_host: TooltipHost
var toast_host: ToastHost
var tutorial_host: TutorialHost

var _layer: CanvasLayer = null
var _dialog_open: bool = false


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = LAYER
	add_child(_layer)

	# Every host is a full-rect Control on this high layer. They MUST be
	# MOUSE_FILTER_IGNORE when idle — the default STOP would swallow every
	# click in the game even with nothing displayed. Interactive children
	# (dialog backdrop, tutorial highlight layer, toast roots) opt back into
	# STOP only while they are actually visible.
	dialog_host = DialogHost.new()
	dialog_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	dialog_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(dialog_host)

	tooltip_host = TooltipHost.new()
	tooltip_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	tooltip_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(tooltip_host)

	toast_host = ToastHost.new()
	toast_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	toast_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(toast_host)

	tutorial_host = TutorialHost.new()
	tutorial_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	tutorial_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(tutorial_host)

	toast_host.set_gate(_can_show_toast)
	tooltip_host.set_gate(_can_trigger_tooltip)
	dialog_host.dialog_opened.connect(_on_dialog_opened)
	dialog_host.dialog_closed.connect(_on_dialog_closed)
	EventBus.screen_changed.connect(_on_screen_changed)


func _exit_tree() -> void:
	if EventBus.screen_changed.is_connected(_on_screen_changed):
		EventBus.screen_changed.disconnect(_on_screen_changed)


# --- Dialogs --------------------------------------------------------------------

## Opens a centered content-sized dialog with custom content. Returns the panel
## so callers can reach into their own content, or null when rejected (a dialog
## is already open). size_hint bounds the panel and use_art selects the jar art
## vs the flat panel style (see DialogHost.open).
func show_dialog(content: Control, title: String = "", closable: bool = true, size_hint: Vector2 = Vector2.ZERO, use_art: bool = true) -> PanelContainer:
	return dialog_host.open(content, title, closable, size_hint, use_art)


## Convenience dialog: title + wrapped, scrollable body text.
func show_text_dialog(title: String, body: String) -> PanelContainer:
	return dialog_host.open_text(title, body)


func close_current_dialog() -> void:
	dialog_host.close()


func is_dialog_open() -> bool:
	return _dialog_open


# --- Tooltips -------------------------------------------------------------------

## Makes `control` long-pressable (0.5s hold, ≤12px movement) to show a small
## icon+text tooltip above it. The control's own interaction still works —
## the press is never swallowed. Re-attaching refreshes the text (used on
## locale change). New triggers are blocked while a dialog is open or a
## tutorial is active (GDD §8).
func attach_tooltip(control: Control, text: String, icon_key: String = "") -> void:
	tooltip_host.attach(control, text, icon_key)


func detach_tooltip(control: Control) -> void:
	tooltip_host.detach(control)


## Programmatic show (e.g. for debug tooling). Any other screen interaction
## (or navigation away / dialog open) dismisses it.
func show_tooltip(anchor: Control, text: String, icon_key: String = "") -> void:
	tooltip_host.show_for(anchor, text, icon_key)


func dismiss_tooltip() -> void:
	tooltip_host.dismiss()


# --- Toasts ---------------------------------------------------------------------

## Queues a toast. `tap_action`, when valid, runs on tap (e.g. navigation);
## without it a tap quick-dismisses. Toasts are held while the gate blocks
## them (fullscreen gameplay / dialog open) unless `allowed_in_fullscreen`.
func push_toast(text: String, icon_key: String = "", tap_action: Callable = Callable(), allowed_in_fullscreen: bool = false) -> void:
	toast_host.push({
		"text": text,
		"icon": icon_key,
		"tap_action": tap_action,
		"allowed_in_fullscreen": allowed_in_fullscreen,
	})


func clear_toasts() -> void:
	toast_host.clear()


# --- Tutorial / FTUE ----------------------------------------------------------------

## Single-step tutorial: dims the screen, highlights `target` with a gold
## ring and arrow, and only clears when the player interacts with the target.
func show_tutorial_step(target: Control, text: String, on_interact: Callable = Callable()) -> void:
	tutorial_host.run_steps([{"target": target, "text": text, "on_interact": on_interact}])


## Multi-step FTUE sequence; each step needs the player to interact with its
## target before the next one starts. Step shape: see TutorialHost.run_steps().
func run_tutorial(steps: Array[Dictionary]) -> void:
	tutorial_host.run_steps(steps)


func cancel_tutorial() -> void:
	tutorial_host.cancel()


# --- Internals ----------------------------------------------------------------------

func _can_show_toast(spec: Dictionary) -> bool:
	if _dialog_open:
		return false
	if ScreenIds.is_fullscreen(ScreenManager.get_current_screen_id()):
		return bool(spec.get("allowed_in_fullscreen", false))
	return true


func _can_trigger_tooltip() -> bool:
	if _dialog_open:
		return false
	if tutorial_host.is_active():
		return false
	return true


func _on_dialog_opened(_dialog: PanelContainer) -> void:
	_dialog_open = true
	tooltip_host.dismiss()


func _on_dialog_closed(_dialog: PanelContainer) -> void:
	_dialog_open = false
	toast_host.process_queue()


func _on_screen_changed(_screen_id: StringName, _previous_screen_id: StringName) -> void:
	tooltip_host.dismiss()
	toast_host.process_queue()
	tutorial_host.refresh_target()
