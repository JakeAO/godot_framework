class_name NakamaAnalyticsBackend
extends IAnalyticsBackend
## Real IAnalyticsBackend on Nakama (TDD §3.17): one batched RPC to the `analytics`
## Go plugin, which writes rows into Nakama's own Postgres — no second service,
## no separate credential. Identity rides the authenticated session (the server
## reads user_id/username from its context; the client never sends it).
## Fire-and-forget: failure = drop the batch + warn once (analytics never block
## gameplay). Inert in mock mode (no real-mode OnlineService) so the gate stays
## hermetic.

const ANALYTICS_FUNCTION: String = "analytics"

var _warned_drop := false


func flush(events: Array[Dictionary]) -> void:
	if events.is_empty() or not OnlineService.is_real_mode():
		return
	var session := OnlineService.get_session()
	if session == null:
		_warn_drop_once("session unavailable")
		return
	# Untyped on purpose (documented exception): real mode holds a NakamaClient;
	# GUT injects a duck-typed fake via OnlineService.start_real_mode_with().
	var client = OnlineService.get_client()
	if client == null:
		_warn_drop_once("client unavailable")
		return
	var text := JSON.stringify(build_payload(events))
	if text.is_empty():
		_warn_drop_once("payload serialization failed")
		return
	var result: NakamaAPI.ApiRpc = await client.rpc_async(session, ANALYTICS_FUNCTION, text)
	if result.is_exception():
		_warn_drop_once("rpc %s" % ANALYTICS_FUNCTION)


## Queue entries -> plugin payload. Pure and static so GUT can pin the wire
## shape without a client or network. ts <= 0 becomes NULL server-side; props
## pass through as raw JSON (JSONB).
static func build_payload(events: Array[Dictionary]) -> Dictionary:
	var out: Array = []
	for e in events:
		var ev := e as Dictionary
		out.append({
			"name": str(ev.get("name", "")),
			"ts": int(ev.get("ts", 0)),
			"session_id": str(ev.get("session_id", "")),
			"props": ev.get("properties", {}),
		})
	return {"events": out}


func _warn_drop_once(context: String) -> void:
	if _warned_drop:
		return
	_warned_drop = true
	push_warning("NakamaAnalyticsBackend: %s; dropping batch (analytics never block gameplay)" % context)
