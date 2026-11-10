extends RefCounted
class_name ISocialBackend
## Interface for the social service (TDD §3.16, v2+ surface; chat realtime per
## TDD §3.24 — Phase E1): friends + teams + chat in ONE backend (one real
## service). All methods are awaitable — implementations may `await` a
## transport internally; callers MUST `await`.
##
## Fallible methods return Variant on purpose: Godot 4.7 typed arrays cannot
## be null, and `null` is the transport/auth-failure signal the manager falls
## back from (cache + warn-once). Success payloads keep their TDD §3.16 types.
## Business failures return {ok: false, error: "<key>"} with a NON-empty key;
## an empty error on failure is the "no such entity" convention (the manager
## maps it to social_unavailable + warn-once).

# --- Friends -------------------------------------------------------------------

func fetch_friends() -> Variant:
	return []


## Sends a PENDING invitation (two-way model — TDD §3.16). Error keys:
## friend_invalid_code / friend_unknown_code / friend_already_added /
## friend_pending_exists / friend_blocked.
func add_friend(_player_code: String) -> Variant:
	return {"ok": false, "error": ""}


func remove_friend(_player_code: String) -> void:
	pass


## Pending invitations in BOTH directions:
## {player_code, name, direction "sent"|"received", ts}.
func fetch_invitations() -> Variant:
	return []


## Accept/reject a RECEIVED invitation; `accept=false` on a SENT one cancels it.
## No pending either way -> error key friend_no_pending.
func respond_invitation(_player_code: String, _accept: bool) -> Variant:
	return {"ok": false, "error": ""}


## Removes the user from friends + pendings and prevents re-adding until
## unblocked (idempotent for an already-blocked user).
func block_user(_player_code: String) -> Variant:
	return {"ok": false, "error": ""}


func unblock_user(_player_code: String) -> Variant:
	return {"ok": true, "error": ""}


## Blocked users: {player_code, name}.
func fetch_blocked() -> Variant:
	return []


# --- Teams -----------------------------------------------------------------------

## Rows: {team_id, name, access_mode "open"|"by-request", power, members,
## banner_recipe}.
func search_teams(_query: String) -> Variant:
	return []


## OPEN teams only; by-request returns error team_by_request. The `team`
## payload is the `team` save-domain shape + access_mode/leader_code/banner
## recipe (TDD §3.4).
func join_team(_team_id: String) -> Variant:
	return {"ok": false, "error": "", "team": {}}


## BY-REQUEST teams; errors team_open / team_request_pending /
## team_already_member. `pending` is true when a request now (or already)
## exists for the local player.
func request_join(_team_id: String) -> Variant:
	return {"ok": false, "error": "", "pending": false}


func leave_team() -> void:
	pass


## The `team` save-domain shape + access_mode/leader_code/banner recipe;
## empty when off-team.
func fetch_team() -> Variant:
	return {}


## Errors team_invalid_name (bad name/access mode) / team_already_on_team;
## creator = leader, and creation joins the new team.
func create_team(_name: String, _access_mode: String, _banner_recipe: Dictionary) -> Variant:
	return {"ok": false, "error": "", "team": {}}


## Any of name/access_mode/banner_recipe; LEADER only (else team_not_leader);
## invalid name/access mode -> team_invalid_name.
func update_team_settings(_settings: Dictionary) -> Variant:
	return {"ok": false, "error": "", "team": {}}


## Leader only; empty for non-leaders and when off-team. Rows:
## {player_code, name, ts}.
func fetch_join_requests() -> Variant:
	return []


## Leader only; approve adds the requester to the roster. One-shot: the
## request is removed either way.
func respond_join_request(_player_code: String, _approve: bool) -> Variant:
	return {"ok": false, "error": ""}


# --- Chat (v3 — realtime per TDD §3.24) --------------------------------------------

## Realtime push of an incoming chat message (row shape identical to the fetch
## rows below). Emitted ONLY while a subscription is active; the manager
## dedupes against its known-id set (a message can arrive via the history
## fetch, the send echo AND this push).
signal chat_message_received(message: Dictionary)

## Messages are {id, sender_code, sender_name, text, ts}.
func fetch_chat_history(_limit: int) -> Variant:
	return []


func send_chat_message(_text: String) -> Variant:
	return {"ok": false, "message": {}}


## Opens the transport if needed and subscribes to the team's channel;
## idempotent (re-subscribe while subscribed = no-op). Off-team ->
## {ok: false, error: "chat_no_team"}. null = transport failure.
func subscribe_chat() -> Variant:
	return {"ok": true, "error": ""}


## Leaves the channel; the underlying transport stays open for sends.
func unsubscribe_chat() -> void:
	pass


# --- Presence (v3+ — TDD §3.25) ------------------------------------------------------

## Batched DELTA of changed entries only: {player_code: {online: bool,
## last_seen: int}}. Emitted as status-presence events arrive; the manager
## merges deltas into its presence map and re-emits what actually changed.
signal presence_updated(presences: Dictionary)

## Connects the transport with appear_online=true if not already connected
## (this client becomes visible to followers), then follows the given users;
## idempotent, and a re-call with a changed set re-follows the diff. null =
## transport failure. Mock mode = no-op success.
func subscribe_presence(_friend_codes: Array[String]) -> Variant:
	return {"ok": true, "error": ""}


## Drops all presence follows; the underlying transport stays open.
func unsubscribe_presence() -> void:
	pass
