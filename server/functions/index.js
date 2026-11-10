// team_ops — the ONE server function in this deployment (BACKEND.md §3).
// Group metadata is writable ONLY via the runtime API (REST CreateGroup/
// UpdateGroup have no metadata field), so team create/update come through here.
// Everything else (friends, join requests, chat, storage) is native REST.
//
// ES5 ONLY (goja VM): var, no let/const, no arrow fns, no async/await,
// no template literals, no default params. No Node APIs, no global state.
//
// Payload:  {"action": "create"|"update", ...}
// Returns:  JSON string — success {"ok": true, error: "", ...} / failure
//           {"ok": false, "error": "<key>"} with keys matching the client's
//           MockSocialBackend error keys (TDD §3.17 mapping table).

var MAX_TEAM_NAME_LENGTH = 24; // parity with MockSocialBackend.MAX_TEAM_NAME_LENGTH
var ACCESS_MODES = ["open", "by-request"];

function InitModule(ctx, logger, nk, initializer) {
	initializer.registerRpc("team_ops", rpcTeamOps);
	initializer.registerRpc("tournament_ops", rpcTournamentOps);
	initializer.registerRpc("leaderboard_ops", rpcLeaderboardOps);
}

function okPayload(result) {
	var out = { ok: true, error: "" };
	for (var k in result) {
		if (result.hasOwnProperty(k)) {
			out[k] = result[k];
		}
	}
	return JSON.stringify(out);
}

function failPayload(errorKey) {
	return JSON.stringify({ ok: false, error: errorKey });
}

function strip(s) {
	return String(s == null ? "" : s).replace(/^\s+|\s+$/g, "");
}

function validName(name) {
	var clean = strip(name);
	return clean.length > 0 && clean.length <= MAX_TEAM_NAME_LENGTH;
}

function buildMetadata(req, fallbackDisplayName) {
	var meta = {
		access_mode: req.access_mode,
		display_name: strip(req.name) || fallbackDisplayName || "",
		power: 0
	};
	if (req.banner_base != null) { meta.banner_base = String(req.banner_base); }
	if (req.banner_icon != null) { meta.banner_icon = String(req.banner_icon); }
	if (req.banner_base_lut != null) { meta.banner_base_lut = String(req.banner_base_lut); }
	if (req.banner_icon_lut != null) { meta.banner_icon_lut = String(req.banner_icon_lut); }
	// H7 icon scale: numeric on the wire, stored as a string like every other
	// banner_* value; the client parses it back with float() (default 1.0).
	if (req.banner_icon_scale != null) { meta.banner_icon_scale = String(req.banner_icon_scale); }
	return meta;
}

function rpcTeamOps(context, logger, nk, payload) {
	// Verified (runtime_javascript_context.go v3.37.0): the JS runtime context
	// is FLAT — ctx.userId / ctx.username / ctx.sessionId (no nested user obj).
	var callerId = context.userId;
	var req = {};
	try {
		req = JSON.parse(payload || "{}");
	} catch (e) {
		return failPayload("bad_payload");
	}
	if (req.action === "create") {
		return actionCreate(callerId, logger, nk, req);
	}
	if (req.action === "update") {
		return actionUpdate(callerId, logger, nk, req);
	}
	return failPayload("bad_payload");
}

function actionCreate(callerId, logger, nk, req) {
	var name = strip(req.name);
	var accessMode = String(req.access_mode || "");
	if (!validName(name) || ACCESS_MODES.indexOf(accessMode) < 0) {
		return failPayload("team_invalid_name");
	}

	// One team per player (mock parity: team_already_on_team). Actual
	// membership blocks; a pending request (state 3) does not.
	var mine = nk.userGroupsList(callerId, 100, null, null);
	if (mine && mine.userGroups) {
		for (var i = 0; i < mine.userGroups.length; i++) {
			var state = mine.userGroups[i].state;
			if (state === 0 || state === 1 || state === 2) {
				return failPayload("team_already_on_team");
			}
		}
	}

	// Group names are unique server-side; a taken name is surfaced with the
	// same key the client shows for invalid names (prototype-grade).
	var existing = nk.groupsList(name, null, null, null, 1, null);
	if (existing && existing.groups && existing.groups.length > 0) {
		return failPayload("team_invalid_name");
	}

	var metadata = buildMetadata(req, name);
	var group;
	try {
		group = nk.groupCreate(callerId, name, callerId, null, null, null, accessMode === "open", metadata, 100);
	} catch (e) {
		logger.error("team_ops create failed: " + e.message);
		return failPayload("bad_payload");
	}
	return okPayload({ team_id: group.id });
}

function actionUpdate(callerId, logger, nk, req) {
	var groupId = String(req.group_id || "");
	if (!groupId) {
		return failPayload("bad_payload");
	}
	var found = nk.groupsGetId([groupId]);
	if (!found || !found.length) {
		return failPayload("team_not_found");
	}
	var group = found[0];
	if (group.creatorId !== callerId) {
		return failPayload("team_not_leader");
	}

	// Merge onto the existing metadata (partial update from the client).
	var meta = {};
	try {
		meta = JSON.parse(group.metadata || "{}");
	} catch (e) {
		meta = {};
	}
	if (!meta || typeof meta !== "object") {
		meta = {};
	}

	var name = strip(req.name);
	if (name) {
		if (!validName(name)) {
			return failPayload("team_invalid_name");
		}
		meta.display_name = name; // display name lives in metadata; group.name is the immutable search key
	}
	var accessMode = String(req.access_mode || "");
	var newOpen = null;
	if (accessMode) {
		if (ACCESS_MODES.indexOf(accessMode) < 0) {
			return failPayload("team_invalid_name");
		}
		meta.access_mode = accessMode;
		newOpen = accessMode === "open";
	}
	var bannerKeys = ["banner_base", "banner_icon", "banner_base_lut", "banner_icon_lut", "banner_icon_scale"];
	for (var i = 0; i < bannerKeys.length; i++) {
		var key = bannerKeys[i];
		if (req[key] != null) {
			meta[key] = String(req[key]);
		}
	}

	try {
		// nil fields = no change (verified in core_group.go UpdateGroup).
		nk.groupUpdate(groupId, null, null, null, null, null, null, newOpen, meta, 100);
	} catch (e) {
		logger.error("team_ops update failed: " + e.message);
		return failPayload("bad_payload");
	}
	return okPayload({ team_id: groupId });
}

// --- tournament_ops (Phase F4) ------------------------------------------------------
// Nakama 3.x tournaments are dynamic leaderboards with NO mode concept (verified in
// server/runtime_javascript_nakama.go v3.37.0 — the old global/friend/team modes are
// gone). Consequences, verified against source:
// - tournamentJoin(id, ownerID, username) is IDEMPOTENT (INSERT ... ON CONFLICT DO
//   NOTHING; re-join is a no-op) and does NOT validate that the owner is a user —
//   a GROUP id can join, which is how team tournaments work here.
// - tournamentRecordWrite(id, ownerID, ...) accepts ANY owner UUID, so a team's
//   progress lives in ONE record owned by the group id (the standings row shows the
//   team name via the record username). Member deltas are applied with the "incr"
//   operator override (atomic server-side add — no read-modify-write races).
// - Solo tournaments: the client writes its own running total directly via
//   write_tournament_record_async (operator "best" keeps a stale low total from
//   clobbering a higher one); joinRequired + enableRanks are set here.
//
// Payload actions:
//   {"action":"ensure", id, title, duration_sec, event_id}  — idempotent create
//   {"action":"team_round", tournament_id, points}          — member delta -> team record
//   {"action":"delete", id}                                 — QA cleanup

function rpcTournamentOps(context, logger, nk, payload) {
	var callerId = context.userId;
	var req = {};
	try {
		req = JSON.parse(payload || "{}");
	} catch (e) {
		return failPayload("bad_payload");
	}
	if (req.action === "ensure") {
		return actionTournamentEnsure(logger, nk, req);
	}
	if (req.action === "team_round") {
		return actionTeamRound(callerId, logger, nk, req);
	}
	if (req.action === "delete") {
		return actionTournamentDelete(logger, nk, req);
	}
	return failPayload("bad_payload");
}

function actionTournamentEnsure(logger, nk, req) {
	var id = strip(req.id);
	if (!id) {
		return failPayload("bad_payload");
	}
	var durationSec = Math.floor(Number(req.duration_sec || 0));
	if (durationSec <= 0) {
		return failPayload("bad_payload");
	}

	// Idempotent: an existing tournament is returned untouched (its schedule was
	// fixed at creation — re-ensure never mutates it).
	var existing = nk.tournamentsGetId([id]);
	if (existing && existing.length > 0) {
		return okPayload({ tournament_id: id, created: false });
	}

	var now = Math.floor(Date.now() / 1000);
	var start = now - 60; // slightly in the past so the window is active immediately
	var end = start + durationSec;
	var meta = { event_id: String(req.event_id || "") };
	try {
		// Argument order verified in runtime_javascript_nakama.go v3.37.0 (the doc
		// comment order in that file is WRONG — the code reads arg4=duration).
		// authoritative=false: solo clients write their own running total directly;
		// team records stay safe because the client API can only write as the
		// session's own user id (group-owned records need a server function).
		nk.tournamentCreate(
			id, false, "desc", "best", durationSec, null, meta,
			strip(req.title) || ("Tournament " + id), "", 0,
			start, end, 0, null, true, true);
	} catch (e) {
		logger.error("tournament_ops ensure failed: " + e.message);
		return failPayload("tournament_create_failed");
	}
	return okPayload({ tournament_id: id, created: true });
}

function actionTeamRound(callerId, logger, nk, req) {
	var tournamentId = strip(req.tournament_id);
	var points = Math.floor(Number(req.points || 0));
	if (!tournamentId || points <= 0) {
		return failPayload("bad_payload");
	}

	// The caller must hold an ACTIVE membership (state 0/1/2; a pending request
	// does not count) in exactly one team.
	var mine = nk.userGroupsList(callerId, 100, null, null);
	var groupId = "";
	var displayName = "";
	if (mine && mine.userGroups) {
		for (var i = 0; i < mine.userGroups.length; i++) {
			var state = mine.userGroups[i].state;
			if (state === 0 || state === 1 || state === 2) {
				groupId = String(mine.userGroups[i].group.id);
				var meta = mine.userGroups[i].group.metadata || {};
				displayName = strip(meta.display_name);
				break;
			}
		}
	}
	if (!groupId) {
		return failPayload("no_team");
	}
	if (!displayName) {
		displayName = "Team";
	}

	try {
		// Idempotent server-side; the record username carries the team name so the
		// standings row renders it without a second lookup.
		nk.tournamentJoin(tournamentId, groupId, displayName);
		// Operator enum keys (api.pb.go): NO_OVERRIDE/BEST/SET/INCREMENT/DECREMENT.
		var rec = nk.tournamentRecordWrite(tournamentId, groupId, displayName, points, 0, null, "increment");
		return okPayload({ team_score: Number(rec.score || 0), record_owner: String(rec.ownerId || "") });
	} catch (e) {
		logger.error("tournament_ops team_round failed: " + e.message);
		return failPayload("tournament_unavailable");
	}
}

function actionTournamentDelete(logger, nk, req) {
	var id = strip(req.id);
	if (!id) {
		return failPayload("bad_payload");
	}
	try {
		nk.tournamentDelete(id);
	} catch (e) {
		logger.error("tournament_ops delete failed: " + e.message);
		return failPayload("tournament_delete_failed");
	}
	return okPayload({ tournament_id: id });
}

// --- leaderboard_ops (Phase E5) ------------------------------------------------------
// The ONE best-score board (TDD §3.26). Creation goes through a server function,
// not the client API: the JS runtime's leaderboardCreate is the only create path
// available here and the client addon exposes no CreateLeaderboard.
//
// Verified in runtime_javascript_nakama.go v3.37.0 (argument order from code, not
// the doc comments):
// - leaderboardCreate(id, authoritative, sortOrder, operator, resetSchedule,
//   metadataMap, enableRanks) is IDEMPOTENT server-side ("created if it doesn't
//   already exist, otherwise its configuration will not be updated") but returns
//   undefined — so the `created` flag below comes from a leaderboardsGetId pre-check.
// - operator "best": a stale low score can never clobber a higher one (same reason
//   as solo tournaments); clients write their own best directly, so
//   authoritative=false. enableRanks=true: the UI shows ranks and around-owner
//   ranking requires ranks to be enabled.

function rpcLeaderboardOps(context, logger, nk, payload) {
	var req = {};
	try {
		req = JSON.parse(payload || "{}");
	} catch (e) {
		return failPayload("bad_payload");
	}
	if (req.action === "ensure") {
		return actionLeaderboardEnsure(logger, nk, req);
	}
	if (req.action === "delete") {
		return actionLeaderboardDelete(logger, nk, req);
	}
	return failPayload("bad_payload");
}

function actionLeaderboardEnsure(logger, nk, req) {
	var id = strip(req.id);
	if (!id) {
		return failPayload("bad_payload");
	}
	var existing = nk.leaderboardsGetId([id]);
	if (existing && existing.length > 0) {
		return okPayload({ leaderboard_id: id, created: false });
	}
	try {
		nk.leaderboardCreate(id, false, "desc", "best", null, {}, true);
	} catch (e) {
		logger.error("leaderboard_ops ensure failed: " + e.message);
		return failPayload("leaderboard_create_failed");
	}
	return okPayload({ leaderboard_id: id, created: true });
}

function actionLeaderboardDelete(logger, nk, req) {
	var id = strip(req.id);
	if (!id) {
		return failPayload("bad_payload");
	}
	try {
		nk.leaderboardDelete(id);
	} catch (e) {
		logger.error("leaderboard_ops delete failed: " + e.message);
		return failPayload("leaderboard_delete_failed");
	}
	return okPayload({ leaderboard_id: id });
}
