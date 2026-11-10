extends Node
## TournamentService (TDD §3.23): the ONLY owner of tournament state. Mock mode
## is INERT — no entries, no submits, nothing faked (GDD §8 gating table:
## disabled offline / in mock, never hidden). Real mode: a WON round while a
## kind-bearing event is active auto-enters and accumulates progress
## (`tournament_points_per_win + floor(score / tournament_score_divisor)`);
## solo totals go to Nakama as the running total (operator "best"), team deltas
## go through the `tournament_ops` server function (group-owned record, atomic
## incr — Nakama 3.x has no native team-mode summation, verified in source).
## Expiry claim: rank-band lookup from the event's `rewards`, one-shot stamp;
## team rewards are divided evenly (floor per member, remainder to the leader —
## each member claims their own slice).

const DOMAIN: String = "tournaments"
const TEAM_DOMAIN: String = "team"
const PROFILE_DOMAIN: String = "profile"

const POINTS_KEY: String = "tournament_points_per_win"
const DEFAULT_POINTS_PER_WIN: int = 10
const DIVISOR_KEY: String = "tournament_score_divisor"
const DEFAULT_DIVISOR: int = 25
const STANDINGS_LIMIT: int = 10

const KIND_SOLO: String = "solo_tournament"
const KIND_TEAM: String = "team_tournament"
const ENTRY_KIND_SOLO: String = "solo"
const ENTRY_KIND_TEAM: String = "team"

signal tournament_progress_changed(event_id: String, progress: int)

var _warned: Dictionary = {}


func _ready() -> void:
	EventBus.gameplay_finished.connect(_on_gameplay_finished)


# --- Availability ------------------------------------------------------------------

## Tournaments need a VERIFIED real backend; mock mode is inert by design.
func is_available() -> bool:
	return OnlineService.is_real_mode() and OnlineService.is_online()


## True when the player holds an entry (entered at any point this event window).
func has_entry(event_id: String) -> bool:
	return not get_entry(event_id).is_empty()


func get_entry(event_id: String) -> Dictionary:
	var domain: Dictionary = SaveSystem.get_domain(DOMAIN)
	var entries: Variant = domain.get("entries", {})
	if typeof(entries) != TYPE_DICTIONARY:
		return {}
	var entry: Variant = (entries as Dictionary).get(event_id, {})
	return (entry as Dictionary).duplicate(true) if typeof(entry) == TYPE_DICTIONARY else {}


## Pure progress formula (remote values; divisor <= 0 guards against div-by-zero).
func points_for(score: int) -> int:
	var base := maxi(int(RemoteConfig.get_value(POINTS_KEY, DEFAULT_POINTS_PER_WIN)), 0)
	var divisor := maxi(int(RemoteConfig.get_value(DIVISOR_KEY, DEFAULT_DIVISOR)), 1)
	return base + maxi(score, 0) / divisor


func _event_by_id(event_id: String) -> Dictionary:
	for event in RemoteConfig.get_events():
		if str(event.get("id", "")) == event_id:
			return event
	return {}


func _tournament_id_of(event: Dictionary) -> String:
	var metadata: Variant = event.get("metadata", {})
	if typeof(metadata) != TYPE_DICTIONARY:
		return ""
	return str((metadata as Dictionary).get("tournament_id", ""))


## "solo_tournament" | "team_tournament" | "" (kind-less events are display-only).
func _kind_of(event: Dictionary) -> String:
	var kind := str(event.get("kind", ""))
	if kind == KIND_SOLO or kind == KIND_TEAM:
		return kind
	return ""


# --- Round flow ----------------------------------------------------------------------

func _on_gameplay_finished(result: Dictionary) -> void:
	if not bool(result.get("won", false)):
		return
	for event in RemoteConfig.get_events():
		var kind := _kind_of(event)
		if kind == "":
			continue
		var event_id := str(event.get("id", ""))
		if event_id == "" or not RemoteConfig.is_event_active(event_id):
			continue
		if kind == KIND_SOLO:
			_process_solo(event, int(result.get("score", 0)))
		else:
			_process_team(event, int(result.get("score", 0)))


func _process_solo(event: Dictionary, score: int) -> void:
	var event_id := str(event.get("id", ""))
	var tournament_id := _tournament_id_of(event)
	if not is_available() or tournament_id == "":
		return
	var entry := get_entry(event_id)
	entry["kind"] = ENTRY_KIND_SOLO
	entry["tournament_id"] = tournament_id
	entry["progress"] = int(entry.get("progress", 0)) + points_for(score)
	if int(entry.get("joined_unix", 0)) == 0:
		entry["joined_unix"] = int(Time.get_unix_time_from_system())
	_store_entry(event_id, entry)
	Analytics.track("tournament_round", {"event": event_id, "kind": ENTRY_KIND_SOLO})
	_submit_solo(tournament_id, int(entry["progress"]))


func _process_team(event: Dictionary, score: int) -> void:
	var event_id := str(event.get("id", ""))
	var tournament_id := _tournament_id_of(event)
	var team: Dictionary = SaveSystem.get_domain(TEAM_DOMAIN)
	if not is_available() or tournament_id == "" or not bool(team.get("on_team", false)):
		return
	var entry := get_entry(event_id)
	entry["kind"] = ENTRY_KIND_TEAM
	entry["tournament_id"] = tournament_id
	entry["progress"] = int(entry.get("progress", 0)) + points_for(score)
	if int(entry.get("joined_unix", 0)) == 0:
		entry["joined_unix"] = int(Time.get_unix_time_from_system())
	_store_entry(event_id, entry)
	Analytics.track("tournament_round", {"event": event_id, "kind": ENTRY_KIND_TEAM})
	_submit_team_delta(tournament_id, points_for(score))


func _store_entry(event_id: String, entry: Dictionary) -> void:
	var domain := SaveSystem.get_domain(DOMAIN)
	var entries: Variant = domain.get("entries", {})
	if typeof(entries) != TYPE_DICTIONARY:
		entries = {}
	(entries as Dictionary)[event_id] = entry
	domain["entries"] = entries
	SaveSystem.set_domain(DOMAIN, domain)
	SaveSystem.save_game()
	tournament_progress_changed.emit(event_id, int(entry.get("progress", 0)))


# --- Network (fire-and-forget; warn-once per failure class) ----------------------------

## Solo: join (idempotent server-side) then submit the RUNNING TOTAL. Operator
## "best" keeps a stale lower total from clobbering a higher one.
func _submit_solo(tournament_id: String, total: int) -> void:
	# Variant on purpose: tests inject a duck-typed fake via the OnlineService seam.
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if client == null or session == null:
		return
	var join: Variant = await client.join_tournament_async(session, tournament_id)
	if join.is_exception():
		_warn_once("join", join)
		return
	var write: Variant = await client.write_tournament_record_async(session, tournament_id, total)
	if write.is_exception():
		_warn_once("write", write)


## Team: the server function verifies membership, ensures the GROUP is joined
## (record username = team display name) and atomically increments the team's
## record — no client-side read-modify-write.
func _submit_team_delta(tournament_id: String, points: int) -> void:
	# Variant on purpose: tests inject a duck-typed fake via the OnlineService seam.
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if client == null or session == null:
		return
	var payload := JSON.stringify({"action": "team_round", "tournament_id": tournament_id, "points": points})
	var rpc: Variant = await client.rpc_async(session, "tournament_ops", payload)
	if rpc.is_exception():
		_warn_once("team_round_rpc", rpc)
		return
	var parsed: Variant = JSON.parse_string(str(rpc.payload))
	if typeof(parsed) != TYPE_DICTIONARY or not bool((parsed as Dictionary).get("ok", false)):
		_warn_once("team_round", rpc)


func _warn_once(op: String, result: Variant) -> void:
	if _warned.has(op):
		return
	_warned[op] = true
	var detail := ""
	if result is NakamaAsyncResult and (result as NakamaAsyncResult).is_exception():
		detail = str((result as NakamaAsyncResult).get_exception()).left(160)
	push_warning("TournamentService: %s failed; continuing without it (%s)" % [op, detail])


# --- Standings -----------------------------------------------------------------------

## {ok, top: [{rank, name, score}], own_rank, own_score} — top-N from the
## tournament records + the player's own row (solo = session user, team = the
## group-owned record). Offline / mock / unknown event = ok:false.
func fetch_standings(event_id: String) -> Dictionary:
	var fail := {"ok": false, "error": "", "top": [], "own_rank": 0, "own_score": 0}
	if not is_available():
		fail["error"] = "offline"
		return fail
	var event := _event_by_id(event_id)
	var tournament_id := _tournament_id_of(event)
	if event.is_empty() or tournament_id == "":
		fail["error"] = "unknown_event"
		return fail
	# Variant on purpose: tests inject a duck-typed fake via the OnlineService seam.
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if client == null or session == null:
		fail["error"] = "offline"
		return fail

	# After end_time the server rejects record lists unless the expiry window is
	# pinned (ErrTournamentOutsideDuration, verified in TournamentRecordsList); for
	# a no-reset schedule the records' expiry IS end_active (calculateTournamentDeadlines),
	# which equals the default window while active — so pinning is always safe.
	var end_active := await _tournament_end_active(client, session, tournament_id)
	var expiry: Variant = end_active if end_active > 0 else null

	var list: Variant = await client.list_tournament_records_async(session, tournament_id, null, STANDINGS_LIMIT, null, expiry)
	if list.is_exception():
		_warn_once("list", list)
		fail["error"] = "fetch_failed"
		return fail
	var top: Array = []
	if list.records != null:
		for rec in list.records as Array:
			top.append(_row_of(rec))

	var own_rank := 0
	var own_score := 0
	if str(get_entry(event_id).get("kind", "")) == ENTRY_KIND_TEAM:
		var team: Dictionary = SaveSystem.get_domain(TEAM_DOMAIN)
		var team_id := str(team.get("team_id", ""))
		if team_id != "":
			var own_list: Variant = await client.list_tournament_records_async(session, tournament_id, [team_id], 1, null, expiry)
			if not own_list.is_exception() and own_list.owner_records != null and (own_list.owner_records as Array).size() > 0:
				own_rank = int(str((own_list.owner_records as Array)[0].rank))
				own_score = int(str((own_list.owner_records as Array)[0].score))
	else:
		var around: Variant = await client.list_tournament_records_around_owner_async(session, tournament_id, session.user_id, 1, null, expiry)
		if not around.is_exception() and around.owner_records != null and (around.owner_records as Array).size() > 0:
			own_rank = int(str((around.owner_records as Array)[0].rank))
			own_score = int(str((around.owner_records as Array)[0].score))
	return {"ok": true, "error": "", "top": top, "own_rank": own_rank, "own_score": own_score}


## end_active of the tournament (0 when unknown). The list_tournaments call must
## pass an end_time filter beyond the tournament's end — with no filter the server
## skips every fixed-end tournament (verified in LocalLeaderboardCache.ListTournaments).
func _tournament_end_active(client: Variant, session: NakamaSession, tournament_id: String) -> int:
	var horizon := int(Time.get_unix_time_from_system()) + 31536000
	var list: Variant = await client.list_tournaments_async(session, 0, 0, 0, horizon, 100)
	if list.is_exception() or list.tournaments == null:
		return 0
	for t in list.tournaments as Array:
		if str(t.id) == tournament_id:
			return int(t.end_active)
	return 0


static func _row_of(rec: Variant) -> Dictionary:
	return {
		"rank": int(str(rec.rank)),
		"name": str(rec.username),
		"score": int(str(rec.score)),
	}


# --- Expiry claim ----------------------------------------------------------------------

## One-shot reward at event expiry: band lookup by own rank, grant, stamp.
## Returns {ok, error, currency, amount}.
func claim(event_id: String) -> Dictionary:
	var fail := {"ok": false, "error": "", "currency": "", "amount": 0}
	if not is_available():
		fail["error"] = "offline"
		return fail
	var event := _event_by_id(event_id)
	var entry := get_entry(event_id)
	if event.is_empty() or entry.is_empty():
		fail["error"] = "not_eligible"
		return fail
	if int(entry.get("claimed_unix", 0)) != 0:
		fail["error"] = "already_claimed"
		return fail
	if RemoteConfig.is_event_active(event_id):
		fail["error"] = "still_active"
		return fail

	var standings := await fetch_standings(event_id)
	if not bool(standings.get("ok", false)):
		fail["error"] = str(standings.get("error", "fetch_failed"))
		return fail
	var rank := int(standings.get("own_rank", 0))
	var band := _band_for(rank, event.get("rewards", []))
	if band.is_empty():
		fail["error"] = "no_reward_band"
		return fail

	var currency := str(band.get("currency", "coins"))
	var amount := int(band.get("amount", 0))
	if str(entry.get("kind", "")) == ENTRY_KIND_TEAM:
		amount = _team_share(amount, event_id)
	if amount > 0:
		_grant(currency, amount)
	entry["claimed_unix"] = int(Time.get_unix_time_from_system())
	_store_entry(event_id, entry)
	Analytics.track("tournament_claimed", {"event": event_id, "currency": currency, "amount": amount})
	return {"ok": true, "error": "", "currency": currency, "amount": amount}


## First band whose [min_rank, max_rank] contains the rank; {} when none.
static func _band_for(rank: int, rewards: Variant) -> Dictionary:
	if typeof(rewards) != TYPE_ARRAY or rank <= 0:
		return {}
	for raw in rewards as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var band := raw as Dictionary
		if rank >= int(band.get("min_rank", 1)) and rank <= int(band.get("max_rank", 0)):
			return band
	return {}


## Floor per current member; the leader (this player, when they lead) also takes
## the remainder. Each member claims their own slice at expiry.
func _team_share(total: int, event_id: String) -> int:
	var team: Dictionary = SaveSystem.get_domain(TEAM_DOMAIN)
	var members: Variant = team.get("members", [])
	var count := (members as Array).size() if typeof(members) == TYPE_ARRAY else 0
	if count <= 1:
		return total
	var share := total / count
	if str(team.get("leader_code", "")) == IdentityService.get_player_code():
		share += total % count
	return share


func _grant(currency: String, amount: int) -> void:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	profile[currency] = int(profile.get(currency, 0)) + amount
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.save_game()
	EventBus.currency_changed.emit(currency, int(profile[currency]))
	EventBus.profile_updated.emit(profile)


## Test/QA seam: clears a tournament entry (and the daily-less domain state).
func clear_entry(event_id: String) -> void:
	var domain := SaveSystem.get_domain(DOMAIN)
	var entries: Variant = domain.get("entries", {})
	if typeof(entries) == TYPE_DICTIONARY:
		(entries as Dictionary).erase(event_id)
	domain["entries"] = entries
	SaveSystem.set_domain(DOMAIN, domain)
	SaveSystem.save_game()
