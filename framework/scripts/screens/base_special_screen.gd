class_name BaseSpecialScreen
extends BaseScreen
## Base for the Special screen slot (GDD §7). The framework ships only a
## placeholder; each prototype BRANCHES the repo and rewrites special_screen.gd
## on top of this base. Subclasses build their content inside
## _build_special_content(host) and refresh it in _refresh_special_content().

func _build_ui() -> void:
	var host := Control.new()
	# Pin full-rect before add_child (layout contract, TDD §4).
	host.anchor_left = 0.0
	host.anchor_top = 0.0
	host.anchor_right = 1.0
	host.anchor_bottom = 1.0
	add_child(host)
	_build_special_content(host)


func _apply_locale() -> void:
	_refresh_special_content()


## Override: build the screen's content inside `host` (a full-rect Control).
## Called once per instance (BaseScreen guards _build_ui).
func _build_special_content(_host: Control) -> void:
	pass


## Override: refresh localized/dynamic content. Runs on every locale change.
func _refresh_special_content() -> void:
	pass
