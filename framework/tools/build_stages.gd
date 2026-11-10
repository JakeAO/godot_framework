extends SceneTree
## One-shot tool: regenerates the default 5-stage ladder in
## res://resources/stages/ (all tap-target, remote-default duration/win score).
## The files are plain content — edit or add them directly for real stage data
## (GDD §5: adding a stage = adding a file). NOTE: -s SceneTree scripts run
## without autoloads, so the dir is duplicated here instead of using Paths.
##
## Run: godot --headless --path . -s res://tools/build_stages.gd

const STAGES_DIR := "res://resources/stages/"
const STAGE_COUNT: int = 5


func _initialize() -> void:
	if DirAccess.open(STAGES_DIR) == null and DirAccess.make_dir_recursive_absolute(STAGES_DIR) != OK:
		push_error("build_stages: could not create %s" % STAGES_DIR)
		quit(1)
		return
	for i in range(1, STAGE_COUNT + 1):
		var def := StageDefinition.new()
		def.id = i
		var err: int = ResourceSaver.save(def, "%sstage_%d.tres" % [STAGES_DIR, i])
		if err != OK:
			push_error("build_stages: failed to save stage %d (err %d)" % [i, err])
			quit(1)
			return
	print("Saved %d default stages to %s" % [STAGE_COUNT, STAGES_DIR])
	quit(0)
