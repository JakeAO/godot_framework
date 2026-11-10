extends Node
## Autoload "GameplayRegistry". Maps gameplay keys to GameplayBase subclass
## scripts so stage data (StageDefinition.gameplay_key) and the global remote
## override (`gameplay_scene`) can select the minigame without code.
##
## The framework is NOT the game (GDD §5): dropping in an alternate mechanic
## (plinko, crane game, match-3, …) via a branch = add its GameplayBase
## subclass + one register() line. Unknown keys fall back to the built-in
## tap-target so a misconfigured stage never bricks the ladder.

const DEFAULT_KEY: String = "tap_target"

var _scripts: Dictionary = {}


func _ready() -> void:
	register(DEFAULT_KEY, TapTargetGameplay)


## Registers (or replaces) the gameplay behind `key`. Duplicate keys warn —
## a branch deliberately overriding a built-in should see it.
func register(key: String, script: GDScript) -> void:
	if key == "":
		push_warning("GameplayRegistry: refusing to register an empty key")
		return
	if _scripts.has(key):
		push_warning("GameplayRegistry: replacing existing gameplay for key '%s'" % key)
	_scripts[key] = script


func unregister(key: String) -> void:
	_scripts.erase(key)


func has(key: String) -> bool:
	return _scripts.has(key)


## Instantiates the registered gameplay for `key`; unknown keys warn and fall
## back to the default so callers always get a playable widget.
func create(key: String) -> GameplayBase:
	var script: Variant = _scripts.get(key, null)
	if not (script is GDScript):
		push_warning("GameplayRegistry: unknown gameplay key '%s'; falling back to '%s'" % [key, DEFAULT_KEY])
		script = _scripts[DEFAULT_KEY]
	var instance: Node = script.new()
	return instance as GameplayBase
