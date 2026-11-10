extends SceneTree
## One-shot tool: regenerates res://resources/theme/game_theme.tres from
## ThemeFactory so the checked-in .tres can never drift from the code.
##
## Run: godot --headless --path . -s res://tools/build_theme.gd

const OUTPUT_PATH: String = "res://resources/theme/game_theme.tres"


func _initialize() -> void:
	var theme := ThemeFactory.create()
	var err: int = ResourceSaver.save(theme, OUTPUT_PATH)
	if err != OK:
		push_error("build_theme: failed to save %s (err %d)" % [OUTPUT_PATH, err])
		quit(1)
		return
	print("Saved theme to ", OUTPUT_PATH)
	quit(0)
