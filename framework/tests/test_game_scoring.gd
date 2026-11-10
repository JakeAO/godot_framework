extends GutTest
## Pure scoring math. No singletons involved, so no setup is needed.


func test_tap_score_base() -> void:
	assert_eq(Scoring.tap_score(0), 10, "first tap of a chain scores base points")


func test_tap_score_chain_bonus() -> void:
	assert_eq(Scoring.tap_score(5), 20, "chain bonus adds 2 per previous consecutive hit")


func test_tap_score_negative_chain_clamped_to_base() -> void:
	assert_eq(Scoring.tap_score(-3), 10, "negative chain clamps to base points")


func test_coins_for_score_normal() -> void:
	assert_eq(Scoring.coins_for_score(150, 2.0), 30, "score 150 with x2 multiplier grants 30 coins")
	assert_eq(Scoring.coins_for_score(99, 1.0), 9, "coin division truncates toward zero")
	assert_eq(Scoring.coins_for_score(10, 1.0), 1, "minimum positive score grants one coin")


func test_coins_for_score_zero_inputs() -> void:
	assert_eq(Scoring.coins_for_score(0, 2.0), 0, "zero score grants no coins")
	assert_eq(Scoring.coins_for_score(150, 0.0), 0, "zero multiplier grants no coins")
	assert_eq(Scoring.coins_for_score(-10, 2.0), 0, "negative score grants no coins")


func test_coins_for_score_negative_multiplier() -> void:
	assert_eq(Scoring.coins_for_score(150, -1.0), 0, "negative multiplier grants no coins")


func test_xp_needed_for_level_curve() -> void:
	assert_eq(Scoring.xp_needed_for_level(1), 100, "level 1 needs 100 XP")
	assert_eq(Scoring.xp_needed_for_level(2), 150, "level 2 needs 150 XP")
	assert_eq(Scoring.xp_needed_for_level(3), 200, "level 3 needs 200 XP")


func test_xp_needed_for_level_clamps_low_levels() -> void:
	assert_eq(Scoring.xp_needed_for_level(0), 100, "levels below 1 clamp to the level-1 requirement")
	assert_eq(Scoring.xp_needed_for_level(-5), 100, "negative levels clamp to the level-1 requirement")
