## Global signal bus. Decouples systems: any manager may emit, any node may listen.
## This is the only sanctioned channel for cross-system communication (see AGENTS.md).
## The signals below are consumed across files via autoload references, which the
## analyzer does not count as usage — suppress the unused-signal warning file-wide.
@warning_ignore("unused_signal")
extends Node

# --- App lifecycle -----------------------------------------------------------
signal app_ready
signal session_started(session_id: String)
signal session_ended(session_id: String)
signal visibility_changed(is_visible: bool)

# --- Navigation --------------------------------------------------------------
signal screen_changed(screen_id: StringName, previous_screen_id: StringName)
signal navigation_requested(screen_id: StringName)

# --- Player / economy --------------------------------------------------------
signal currency_changed(currency: String, amount: int)
signal profile_updated(profile: Dictionary)
signal level_upped(level: int)
## Emitted after a Shop purchase fully applies (save stamped). TDD §3.20.
signal shop_purchased(item_id: String)
## Emitted when the shop domain changes outside a purchase (H8 shard grants):
## consumers of ownership state (Profile) refresh from the save.
signal shop_domain_changed(shop_domain: Dictionary)
## Emitted when the piggy bank balance changes (deposit or redemption). TDD §3.21.
signal piggy_bank_changed(balance: int)
## Emitted after any Gift Pile run mutation (start, reveal, save, cash out,
## loss). `run` is untyped on purpose: null = no active run. TDD §3.22.
signal gift_pile_run_changed(run)

# --- Gameplay ----------------------------------------------------------------
signal gameplay_started(context: Dictionary)
signal gameplay_finished(result: Dictionary)

# --- Config / experiments ----------------------------------------------------
signal config_loaded
signal config_failed(error_string: String)
signal experiment_exposed(experiment_name: String, variant_id: String)

# --- Social (TDD §3.16) --------------------------------------------------------
signal social_friends_changed(friends: Array[Dictionary])
signal social_invitations_changed(invitations: Array[Dictionary])
signal social_team_changed(team: Dictionary)
signal social_chat_message(message: Dictionary)
## Batched presence DELTA {player_code: {online: bool, last_seen: int}} — only
## the entries that actually changed (TDD §3.25).
signal social_presence_changed(presences: Dictionary)
signal save_sync_completed(success: bool)

# --- Backend connection (TDD §3.18) ---------------------------------------------
## Emitted by OnlineService on TRANSITIONS only (not per probe). Mock mode
## never emits (permanently online).
signal backend_state_changed(online: bool)

# --- Matchmaking (TDD §3.27) ------------------------------------------------------
## Emitted by MatchmakingService on every state transition. States:
## "idle" | "queued" | "matched" | "in_match". Payload: matched carries
## {opponents: [{name, player_code}]}; in_match carries {match_id}.
signal matchmaking_state_changed(state: String, payload: Dictionary)
