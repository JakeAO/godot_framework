class_name GameResult
extends RefCounted
## Immutable snapshot of a finished round. Carries everything the results
## screen and analytics need, and serializes to Dictionary for the
## EventBus.gameplay_finished signal (which is Dictionary-typed).

var stage_id: int = 1
var score: int = 0
var best_score: int = 0
var is_new_best: bool = false
var coins_earned: int = 0
var xp_earned: int = 0
var won: bool = false
var duration_sec: float = 0.0
## Active campaign modifiers that scaled this round: {stat, multiplier, title}.
var modifiers_applied: Array[Dictionary] = []


func to_dict() -> Dictionary:
	return {
		"stage_id": stage_id,
		"score": score,
		"best_score": best_score,
		"is_new_best": is_new_best,
		"coins_earned": coins_earned,
		"xp_earned": xp_earned,
		"won": won,
		"duration_sec": duration_sec,
		"modifiers_applied": modifiers_applied.duplicate(),
	}
