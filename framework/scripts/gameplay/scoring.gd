class_name Scoring
extends RefCounted
## Pure scoring math for the tap-target round. Static and side-effect free so
## GUT can test it directly and gameplay + results share one source of truth.

const BASE_TAP_POINTS: int = 10
const COMBO_BONUS_PER_CHAIN: int = 2
const COINS_PER_POINT: int = 10
const BASE_XP_PER_LEVEL: int = 100
const XP_GROWTH_PER_LEVEL: int = 50


## Points for a hit, where `chain` is the number of consecutive successful
## taps before this one (the first tap of a chain scores BASE_TAP_POINTS).
static func tap_score(chain: int) -> int:
	return BASE_TAP_POINTS + maxi(chain, 0) * COMBO_BONUS_PER_CHAIN


## Coins granted for a final score, scaled by an A/B multiplier.
## Returns 0 for non-positive scores or multipliers.
static func coins_for_score(score: int, multiplier: float) -> int:
	if score <= 0 or multiplier <= 0.0:
		return 0
	return int(float(score) / float(COINS_PER_POINT) * multiplier)


## XP needed to go from `level` to the next one (GDD §5): L1→2: 100,
## L2→3: 150, L3→4: 200, … Levels below 1 clamp to the level-1 requirement.
static func xp_needed_for_level(level: int) -> int:
	return BASE_XP_PER_LEVEL + XP_GROWTH_PER_LEVEL * maxi(maxi(level, 1) - 1, 0)
