extends Node
## Autoload "StageCatalog". The data-driven stage ladder: one StageDefinition
## .tres per stage under res://resources/stages/, loaded sorted by id. Adding
## a stage = adding a file (GDD §5). The effective-duration / effective-
## win-score fallback rules (stage value ≤ 0 → remote default) live here as
## the single source so no screen re-implements them.

const FALLBACK_STAGE_COUNT: int = 5
const ROUND_DURATION_KEY: String = "round_duration_sec"
const DEFAULT_ROUND_DURATION: float = 30.0
const WIN_SCORE_KEY: String = "win_score"
const DEFAULT_WIN_SCORE: int = 150

var _stages: Array[StageDefinition] = []


func _ready() -> void:
	load_stages(Paths.STAGES_DIR)


## Loads and sorts the ladder from `dir`. Returns the stage count. A missing
## or empty dir warns and falls back to a generic tap-target ladder so
## existing saves stay playable (tests use this seam with a temp dir).
func load_stages(dir: String) -> int:
	_stages.clear()
	for file in _list_stage_files(dir):
		var res: Resource = load(dir + file)
		if res is StageDefinition:
			_stages.append(res as StageDefinition)
		else:
			push_warning("StageCatalog: %s is not a StageDefinition; skipped" % file)
	if _stages.is_empty():
		push_warning("StageCatalog: no stages found in %s; using the built-in fallback ladder" % dir)
		for i in FALLBACK_STAGE_COUNT:
			var def := StageDefinition.new()
			def.id = i + 1
			_stages.append(def)
	_stages.sort_custom(_sort_by_id)
	return _stages.size()


func stage_count() -> int:
	return _stages.size()


## The stage for `id`, clamped to ladder bounds — a save from a longer ladder
## degrades gracefully instead of stranding the player past the end.
func get_stage(id: int) -> StageDefinition:
	if _stages.is_empty():
		var def := StageDefinition.new()
		def.id = 1
		return def
	var index := clampi(id, 1, _stages.size()) - 1
	return _stages[index]


func effective_duration(stage_id: int) -> float:
	var own := get_stage(stage_id).duration_sec
	if own > 0.0:
		return own
	return float(RemoteConfig.get_value(ROUND_DURATION_KEY, DEFAULT_ROUND_DURATION))


func effective_win_score(stage_id: int) -> int:
	var own := get_stage(stage_id).win_score
	if own > 0:
		return own
	return int(RemoteConfig.get_value(WIN_SCORE_KEY, DEFAULT_WIN_SCORE))


func _sort_by_id(a: StageDefinition, b: StageDefinition) -> bool:
	return a.id < b.id


func _list_stage_files(dir: String) -> Array[String]:
	var files: Array[String] = []
	var dir_access := DirAccess.open(dir)
	if dir_access == null:
		return files
	dir_access.list_dir_begin()
	var file_name := dir_access.get_next()
	while file_name != "":
		if not dir_access.current_is_dir() and file_name.ends_with(".tres"):
			files.append(file_name)
		file_name = dir_access.get_next()
	return files
