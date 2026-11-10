class_name StageDefinition
extends Resource
## Data-driven stage entry (GDD §5). One .tres per stage under
## res://resources/stages/ — adding a stage = adding a file, no code edits.
## The framework is NOT the game: gameplay_key routes this stage to any
## registered GameplayBase subclass (tap-target today; plinko/crane/match-3/…
## via branches).

@export var id: int = 1
@export var name_key: String = ""
@export var gameplay_key: String = "tap_target"
@export var duration_sec: float = 0.0
@export var win_score: int = 0
