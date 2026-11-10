class_name StreakLogic
## Pure daily-streak logic over the "profile" save domain (GDD §8 / TDD §3.21).
## Every function is static and returns a NEW dict (no in-place mutation), so
## callers own persistence. Date math runs on YYYY-MM-DD strings through a small
## days-from-civil helper — no engine datetime calls, so tests can pin any dates.

const MIN_ROUNDS_KEY: String = "streak_min_rounds_per_day"
const REWARDS_KEY: String = "streak_rewards"
const RECOVERY_COINS_KEY: String = "streak_recovery_coins"
const DEFAULT_MIN_ROUNDS: int = 1
const DEFAULT_RECOVERY_COINS: int = 200

## Bumps today's round counter, rolling the day over (and re-arming a fresh
## break's one-shot recovery) when the date changes.
static func register_round(profile: Dictionary, today_str: String) -> Dictionary:
	var p := profile.duplicate(true)
	if str(p.get("streak_date", "")) != today_str:
		p["streak_date"] = today_str
		p["streak_rounds_today"] = 0
		var last := str(p.get("streak_last_date", ""))
		if last != "" and _day_number(today_str) - _day_number(last) > 1:
			p["streak_recovered"] = false
	p["streak_rounds_today"] = int(p.get("streak_rounds_today", 0)) + 1
	return p

## True when today's requirement is met and the streak is alive (last claim was
## yesterday, or there is no prior claim yet).
static func is_claimable(profile: Dictionary, today_str: String) -> bool:
	if str(profile.get("streak_date", "")) != today_str:
		return false
	if int(profile.get("streak_rounds_today", 0)) < _min_rounds():
		return false
	var last := str(profile.get("streak_last_date", ""))
	if last == "":
		return true
	return _day_number(today_str) - _day_number(last) == 1

## Grants the reward for the current streak length and advances it. Returns
## {profile, coins}; a no-op (coins=0, profile deep-copied unchanged) when the
## streak is not claimable.
static func claim_reward(profile: Dictionary, today_str: String) -> Dictionary:
	if not is_claimable(profile, today_str):
		return {"profile": profile.duplicate(true), "coins": 0}
	var rewards := _rewards()
	var idx := clampi(int(profile.get("streak_days", 0)), 0, rewards.size() - 1)
	var coins := int(rewards[idx])
	var p := profile.duplicate(true)
	p["streak_last_date"] = today_str
	p["streak_days"] = int(p.get("streak_days", 0)) + 1
	p["streak_rounds_today"] = 0
	p["streak_date"] = today_str
	p["streak_recovered"] = false
	return {"profile": p, "coins": coins}

## True when a prior streak has lapsed (a day was missed) and is recoverable.
static func is_broken(profile: Dictionary, today_str: String) -> bool:
	if int(profile.get("streak_days", 0)) <= 0:
		return false
	var last := str(profile.get("streak_last_date", ""))
	if last == "":
		return false
	return _day_number(today_str) - _day_number(last) > 1

## True when the break can still be recovered (broken AND not already recovered).
static func can_recover(profile: Dictionary, today_str: String) -> bool:
	return is_broken(profile, today_str) and not bool(profile.get("streak_recovered", false))

## Restores a broken streak so today's claim continues it (not restarts it):
## back-dates the last claim to yesterday and arms the one-shot flag. Returns
## {profile, cost_ok} where cost_ok reports whether the coin path is affordable;
## a no-op (cost_ok=false) when there is nothing to recover.
static func recover(profile: Dictionary, today_str: String) -> Dictionary:
	if not can_recover(profile, today_str):
		return {"profile": profile.duplicate(true), "cost_ok": false}
	var p := profile.duplicate(true)
	p["streak_last_date"] = _minus_one_day(today_str)
	p["streak_recovered"] = true
	return {"profile": p, "cost_ok": int(profile.get("coins", 0)) >= _recovery_coins()}

# --- Public config access (for UI surfaces; defaults mirror GDD §9) ------------

static func min_rounds() -> int:
	return _min_rounds()


static func rewards_table() -> Array[int]:
	return _rewards()


static func recovery_cost() -> int:
	return _recovery_coins()


# --- Config access (defaults mirror GDD §9) -----------------------------------

static func _min_rounds() -> int:
	return maxi(int(RemoteConfig.get_value(MIN_ROUNDS_KEY, DEFAULT_MIN_ROUNDS)), 0)


static func _rewards() -> Array[int]:
	var v: Variant = RemoteConfig.get_value(REWARDS_KEY, null)
	if typeof(v) == TYPE_ARRAY and not (v as Array).is_empty():
		var out: Array[int] = []
		for e in v:
			out.append(int(e))
		return out
	return [50, 75, 100, 125, 150]


static func _recovery_coins() -> int:
	return maxi(int(RemoteConfig.get_value(RECOVERY_COINS_KEY, DEFAULT_RECOVERY_COINS)), 0)

# --- Date math (days-from-civil; no engine datetime calls) ---------------------

static func _parse_date(day_str: String) -> Array[int]:
	var parts := day_str.split("-")
	if parts.size() != 3:
		return [1970, 1, 1]
	return [int(parts[0]), int(parts[1]), int(parts[2])]


## Floor integer division (this build's parser rejects the `//` operator; the
## project convention is float division + an explicit int cast).
static func _floor_div(a: int, b: int) -> int:
	return int(floor(float(a) / float(b)))


## Days since the civil epoch for a YYYY-MM-DD string (Howard Hinnant's
## days-from-civil). Only differences are used, so any consistent offset works.
static func _day_number(day_str: String) -> int:
	var d := _parse_date(day_str)
	var y := d[0]
	var m := d[1]
	var day := d[2]
	if m <= 2:
		y -= 1
	var era := _floor_div(y, 400)
	var yoe := y - era * 400
	var mm := (m - 3) if m > 2 else (m + 9)
	var doy := _floor_div(153 * mm + 2, 5) + day - 1
	var doe := yoe * 365 + _floor_div(yoe, 4) - _floor_div(yoe, 100) + doy
	return era * 146097 + doe - 719468


static func _is_leap(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


static func _days_in_month(y: int, m: int) -> int:
	match m:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			return 29 if _is_leap(y) else 28
	return 30


## The YYYY-MM-DD string one calendar day before the given date.
static func _minus_one_day(day_str: String) -> String:
	var d := _parse_date(day_str)
	var y := d[0]
	var m := d[1]
	var dd := d[2] - 1
	if dd < 1:
		m -= 1
		if m < 1:
			m = 12
			y -= 1
		dd = _days_in_month(y, m)
	return "%04d-%02d-%02d" % [y, m, dd]
