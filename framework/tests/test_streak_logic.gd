extends GutTest
## Pure daily-streak logic (core/streak_logic.gd, GDD §8 / TDD §3.21). All cases
## use fixed YYYY-MM-DD dates and plain profile dicts — no save system, no clock.

const TODAY: String = "2026-11-07"
const YESTERDAY: String = "2026-11-06"
const TWO_DAYS_AGO: String = "2026-11-05"


func _p(overrides := {}) -> Dictionary:
	var base := {
		"coins": 500,
		"streak_days": 0,
		"streak_last_date": "",
		"streak_rounds_today": 0,
		"streak_date": "",
		"streak_recovered": false,
	}
	for k in overrides:
		base[k] = overrides[k]
	return base


# --- Date math -----------------------------------------------------------------

func test_day_number_and_minus_one_day() -> void:
	assert_eq(StreakLogic._day_number(TODAY) - StreakLogic._day_number(YESTERDAY), 1, "consecutive days differ by one")
	assert_eq(StreakLogic._minus_one_day(TODAY), YESTERDAY, "minus one day across a plain boundary")
	assert_eq(StreakLogic._minus_one_day("2026-03-01"), "2026-02-28", "non-leap February end")
	assert_eq(StreakLogic._minus_one_day("2024-03-01"), "2024-02-29", "leap February end")
	assert_eq(StreakLogic._minus_one_day("2026-01-01"), "2025-12-31", "year boundary")


# --- register_round ------------------------------------------------------------

func test_register_round_bumps_and_rolls_over() -> void:
	var p := _p({"streak_date": YESTERDAY, "streak_rounds_today": 3})
	var rolled := StreakLogic.register_round(p, TODAY)
	assert_eq(int(rolled["streak_rounds_today"]), 1, "new date resets the counter then bumps")
	var again := StreakLogic.register_round(rolled, TODAY)
	assert_eq(int(again["streak_rounds_today"]), 2, "same-day round increments in place")


func test_register_round_rearms_recovery_on_a_fresh_break() -> void:
	var p := _p({"streak_days": 5, "streak_last_date": TWO_DAYS_AGO, "streak_date": TWO_DAYS_AGO, "streak_recovered": true})
	var r := StreakLogic.register_round(p, TODAY)
	assert_false(bool(r["streak_recovered"]), "a new broken day re-arms the one-shot recovery")


# --- is_claimable --------------------------------------------------------------

func test_is_claimable_needs_rounds_and_an_alive_day() -> void:
	assert_false(StreakLogic.is_claimable(_p({"streak_date": TODAY, "streak_rounds_today": 0}), TODAY), "below the daily requirement is not claimable")
	assert_true(StreakLogic.is_claimable(_p({"streak_date": TODAY, "streak_rounds_today": 1}), TODAY), "met + no prior claim is claimable")
	assert_true(StreakLogic.is_claimable(_p({"streak_date": TODAY, "streak_rounds_today": 2, "streak_last_date": YESTERDAY, "streak_days": 3}), TODAY), "met + claimed yesterday is claimable")
	assert_false(StreakLogic.is_claimable(_p({"streak_date": TODAY, "streak_rounds_today": 2, "streak_last_date": TODAY, "streak_days": 3}), TODAY), "already claimed today is not claimable again")
	assert_false(StreakLogic.is_claimable(_p({"streak_date": YESTERDAY, "streak_rounds_today": 5}), TODAY), "rounds from a prior date do not count")


# --- claim_reward --------------------------------------------------------------

func test_claim_reward_grants_by_streak_length_and_advances() -> void:
	var first := StreakLogic.claim_reward(_p({"streak_date": TODAY, "streak_rounds_today": 1}), TODAY)
	assert_eq(int(first["coins"]), 50, "first claim pays rewards[0]")
	assert_eq(int((first["profile"] as Dictionary)["streak_days"]), 1, "claiming advances the streak")
	assert_eq(str((first["profile"] as Dictionary)["streak_last_date"]), TODAY, "claim stamps today as the last date")

	var mid := StreakLogic.claim_reward(_p({"streak_date": TODAY, "streak_rounds_today": 2, "streak_days": 3}), TODAY)
	assert_eq(int(mid["coins"]), 125, "claim at length 3 pays rewards[3]")

	var capped := StreakLogic.claim_reward(_p({"streak_date": TODAY, "streak_rounds_today": 2, "streak_days": 40}), TODAY)
	assert_eq(int(capped["coins"]), 150, "long streaks cap at the last table entry")


func test_claim_reward_is_a_noop_when_not_claimable() -> void:
	var original := _p({"streak_date": TODAY, "streak_rounds_today": 0})
	var result := StreakLogic.claim_reward(original, TODAY)
	assert_eq(int(result["coins"]), 0, "no reward when not claimable")
	assert_eq(result["profile"], original, "profile is returned unchanged (deep-equal)")


# --- break + recovery ----------------------------------------------------------

func test_is_broken_after_a_missed_day() -> void:
	assert_true(StreakLogic.is_broken(_p({"streak_days": 4, "streak_last_date": TWO_DAYS_AGO}), TODAY), "a missed day breaks the streak")
	assert_false(StreakLogic.is_broken(_p({"streak_days": 4, "streak_last_date": YESTERDAY}), TODAY), "claimed yesterday is still alive")
	assert_false(StreakLogic.is_broken(_p({"streak_days": 0, "streak_last_date": TWO_DAYS_AGO}), TODAY), "no streak to break when length is zero")


func test_recover_restores_and_reports_affordability() -> void:
	var rich := StreakLogic.recover(_p({"coins": 500, "streak_days": 4, "streak_last_date": TWO_DAYS_AGO}), TODAY)
	assert_eq(str((rich["profile"] as Dictionary)["streak_last_date"]), YESTERDAY, "recovery back-dates the last claim to yesterday")
	assert_true(bool((rich["profile"] as Dictionary)["streak_recovered"]), "recovery arms the one-shot flag")
	assert_true(bool(rich["cost_ok"]), "affordable coin path reports cost_ok")

	var poor := StreakLogic.recover(_p({"coins": 10, "streak_days": 4, "streak_last_date": TWO_DAYS_AGO}), TODAY)
	assert_false(bool(poor["cost_ok"]), "unaffordable coin path reports cost_ok=false (RV still available)")


func test_recover_is_one_shot_per_break() -> void:
	var once := StreakLogic.recover(_p({"coins": 500, "streak_days": 4, "streak_last_date": TWO_DAYS_AGO}), TODAY)
	assert_false(StreakLogic.can_recover(once["profile"], TODAY), "a recovered break cannot be recovered again")
	var twice := StreakLogic.recover(once["profile"], TODAY)
	assert_false(bool(twice["cost_ok"]), "second recovery is a no-op")
