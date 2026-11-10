extends Node
## LeaderboardService (TDD §3.26): the ONLY owner of leaderboard state. ONE
## board (`lb_best_score`, operator "best" — a stale low score can never clobber
## a higher one), two listing scopes: global (plain list) and friends
## (owner_ids = the friend user ids). Mock mode is INERT — no fetches, no
## submits, nothing faked (GDD §8 gating table: disabled offline / in mock,
## never hidden). Real mode: `submit_best` is a fire-and-forget upsert fired
## from the stage-clear flow ONLY when the local best improves (same hook where
## XP/rewards are granted — gameplay_finished carries is_new_best); it never
## blocks play. The board itself is created server-side by the `leaderboard_ops`
## function (DevTools "Ensure leaderboards (E5)" + probe step) — the client API
## has no create path.

const LEADERBOARD_ID: String = "lb_best_score"
const SCOPE_GLOBAL: String = "global"
const SCOPE_FRIENDS: String = "friends"
const DEFAULT_LIMIT: int = 20
const MAX_LIMIT: int = 100

var _warned: Dictionary = {}


func _ready() -> void:
	EventBus.gameplay_finished.connect(_on_gameplay_finished)


# --- Availability ------------------------------------------------------------------

## Leaderboards need a VERIFIED real backend; mock mode is inert by design.
func is_available() -> bool:
	return OnlineService.is_real_mode() and OnlineService.is_online()


# --- Submission --------------------------------------------------------------------

## Fire-and-forget upsert of the player's best score (operator "best" keeps the
## max server-side). No-op when unavailable or non-positive.
func submit_best(score: int) -> void:
	if not is_available() or score <= 0:
		return
	_submit(score)


func _on_gameplay_finished(result: Dictionary) -> void:
	if not bool(result.get("is_new_best", false)):
		return
	submit_best(int(result.get("best_score", 0)))


func _submit(score: int) -> void:
	# Variant on purpose: tests inject a duck-typed fake via the OnlineService seam.
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if client == null or session == null:
		return
	var write: Variant = await client.write_leaderboard_record_async(session, LEADERBOARD_ID, score)
	if write.is_exception():
		_warn_once("write", write)


func _warn_once(op: String, result: Variant) -> void:
	if _warned.has(op):
		return
	_warned[op] = true
	var detail := ""
	if result is NakamaAsyncResult and (result as NakamaAsyncResult).is_exception():
		detail = str((result as NakamaAsyncResult).get_exception()).left(160)
	push_warning("LeaderboardService: %s failed; continuing without it (%s)" % [op, detail])


# --- Fetch ---------------------------------------------------------------------------

## {rank, name, score, is_self} rows for the scope (global = plain list; friends
## = owner_ids-filtered to the friend user ids). The own row comes from the
## around-owner call and is merged in even when outside top-N (pinned last).
## Unavailable / no friends / fetch failure = empty array (the UI shows its
## disabled state before calling, per §3.18).
##
## Verified wire shape (core_leaderboard.go LeaderboardRecordsList, v3.37.0):
## with NON-EMPTY owner_ids the filtered rows ride in `owner_records` (sorted +
## ranks filled) while `records` stays the plain global top-N window — friends
## scope must read owner_records or it would render global rows.
func fetch_leaderboard(scope: String = SCOPE_GLOBAL, limit: int = DEFAULT_LIMIT) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	if not is_available():
		return empty
	# Variant on purpose: tests inject a duck-typed fake via the OnlineService seam.
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if client == null or session == null:
		return empty
	limit = clampi(limit, 1, MAX_LIMIT)

	var owner_ids: Array[String] = []
	if scope == SCOPE_FRIENDS:
		for row in SocialManager.get_friends_cache():
			var uid := str(row.get("user_id", ""))
			if not uid.is_empty():
				owner_ids.append(uid)
		if owner_ids.is_empty():
			return empty

	var list: Variant = await client.list_leaderboard_records_async(session, LEADERBOARD_ID, owner_ids if scope == SCOPE_FRIENDS else null, null, limit, null)
	if list.is_exception():
		_warn_once("list", list)
		return empty
	# Friends scope: the filtered rows arrive in owner_records (see doc above);
	# global scope: the plain top-N window in records.
	var source: Variant = list.owner_records if scope == SCOPE_FRIENDS else list.records
	var rows := _map_rows(source, str(session.user_id))

	# Verified in core_leaderboard.go v3.37.0 (getLeaderboardRecordsHaystack):
	# the owner's OWN row rides in `records` (the window list), NOT in
	# owner_records — scan the window for it.
	var around: Variant = await client.list_leaderboard_records_around_owner_async(session, LEADERBOARD_ID, str(session.user_id), null, 1, null)
	if not around.is_exception() and around.records != null:
		for rec in around.records as Array:
			if str(rec.owner_id) == str(session.user_id):
				if not _has_self(rows):
					rows.append(_row_of(rec, str(session.user_id)))
				break
	return rows


# --- Static pure mappers (fixture-testable) ------------------------------------------

## rank/score are JSON STRINGS on the wire (same gotcha as tournament records).
static func _row_of(rec: Variant, self_user_id: String) -> Dictionary:
	return {
		"rank": int(str(rec.rank)),
		"name": str(rec.username),
		"score": int(str(rec.score)),
		"is_self": str(rec.owner_id) == self_user_id,
	}


static func _map_rows(recs: Variant, self_user_id: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if recs != null:
		for rec in recs as Array:
			rows.append(_row_of(rec, self_user_id))
	return rows


static func _has_self(rows: Array[Dictionary]) -> bool:
	for row in rows:
		if bool(row.get("is_self", false)):
			return true
	return false
