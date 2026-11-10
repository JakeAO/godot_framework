extends GutTest
## NakamaSocialBackend static mappers pinned against recorded fixture shapes
## (TDD §3.17 mapping table). Hermetic by construction: pure functions plus
## Api* fixtures built through the addon's own deserializer — no client, no
## network, no session.

const TS_SAMPLE: String = "2026-11-07T19:31:21Z"


# --- User / friend rows -------------------------------------------------------------

func test_map_user_row_uses_summary_when_present() -> void:
	var summary := {
		"name": "Ada",
		"level": 7,
		"best_score": 1240,
		"portrait_icon": "gold",
		"portrait_flair": "ring_gold",
		"portrait_crown": "crown_silver",
		# Merged in by _summaries_for from the profile/last_seen storage object (TDD §3.25).
		"last_seen": 1760000000,
	}
	var row: Dictionary = NakamaSocialBackend.map_user_row("WGTJ-DMPG", summary)
	assert_eq(int(row.get("last_seen")), 1760000000, "last-seen parsed from the storage-object fixture")
	assert_eq(str(row.get("name")), "Ada", "summary name wins")
	assert_eq(int(row.get("level")), 7, "summary level")
	assert_eq(int(row.get("best_score")), 1240, "summary best score")
	assert_eq(str(row.get("portrait_icon")), "gold", "summary portrait icon")
	assert_eq(str(row.get("portrait_flair")), "ring_gold", "summary flair")
	assert_eq(str(row.get("portrait_crown")), "crown_silver", "summary crown")
	assert_eq(str(row.get("player_code")), "WGTJ-DMPG", "code is the username")


func test_map_user_row_falls_back_to_mock_defaults() -> void:
	var row: Dictionary = NakamaSocialBackend.map_user_row("WGTJ-DMPG", {})
	assert_eq(str(row.get("name")), "WGTJ-DMPG", "missing summary falls back to the code as name")
	assert_eq(int(row.get("level")), 1, "default level")
	assert_eq(int(row.get("best_score")), 0, "default score")
	assert_eq(str(row.get("portrait_icon")), "classic", "default portrait icon")
	assert_eq(str(row.get("portrait_flair")), "none", "default flair")
	assert_eq(str(row.get("portrait_crown")), "none", "default crown")
	assert_eq(int(row.get("last_seen")), 0, "missing last-seen defaults to 0 (plain row line)")


func test_map_user_row_carries_user_id() -> void:
	# TDD §3.26: the leaderboard friends scope lists records by the friend's
	# Nakama user UUID — the row must carry it (the mock synthesizes fake ids).
	var row: Dictionary = NakamaSocialBackend.map_user_row("WGTJ-DMPG", {}, "uuid-abc-123")
	assert_eq(str(row.get("user_id")), "uuid-abc-123", "Nakama user UUID rides on the row")
	var default: Dictionary = NakamaSocialBackend.map_user_row("WGTJ-DMPG", {})
	assert_eq(str(default.get("user_id")), "", "absent id defaults to empty string")


func test_name_from_summary_falls_back_to_username() -> void:
	assert_eq(NakamaSocialBackend.name_from_summary("WGTJ-DMPG", {"name": "Ada"}), "Ada", "summary name used")
	assert_eq(NakamaSocialBackend.name_from_summary("WGTJ-DMPG", {}), "WGTJ-DMPG", "username fallback")


# --- Teams ---------------------------------------------------------------------------

func test_group_channel_id_format() -> void:
	# Live-verified against Nakama 3.37.0: mode.subject.subcontext.label with
	# empty subcontext+label — two trailing dots.
	assert_eq(NakamaSocialBackend.group_channel_id("abc-123"), "3.abc-123..", "group channel id format")


func test_map_team_row_open_with_metadata() -> void:
	var group := NakamaAPI.ApiGroup.create(NakamaAPI, {
		"id": "group-1",
		"name": "raw-name",
		"open": true,
		"creator_id": "user-1",
		"metadata": JSON.stringify({
			"display_name": "Alpha Squad",
			"access_mode": "open",
			"power": 42,
			"banner_base": "base_gold",
			"banner_icon": "icon_star",
			"banner_base_lut": "lut_warm",
			"banner_icon_lut": "lut_cool",
			"banner_icon_scale": 1.25,
		}),
	})
	var row: Dictionary = NakamaSocialBackend.map_team_row(group)
	assert_eq(str(row.get("team_id")), "group-1", "id")
	assert_eq(str(row.get("name")), "Alpha Squad", "display_name wins over raw name")
	assert_eq(str(row.get("access_mode")), "open", "metadata access mode")
	assert_eq(int(row.get("power")), 42, "metadata power")
	var recipe: Dictionary = row.get("banner_recipe", {})
	assert_eq(str(recipe.get("base")), "base_gold", "recipe base")
	assert_eq(str(recipe.get("icon")), "icon_star", "recipe icon")
	assert_eq(str(recipe.get("base_lut")), "lut_warm", "recipe base lut")
	assert_eq(str(recipe.get("icon_lut")), "lut_cool", "recipe icon lut")
	assert_almost_eq(float(recipe.get("icon_scale", 0.0)), 1.25, 0.0001, "recipe icon scale (numeric metadata form)")


func test_map_team_row_closed_without_metadata_falls_back() -> void:
	var group := NakamaAPI.ApiGroup.create(NakamaAPI, {
		"id": "group-2",
		"name": "Closed Crew",
		"open": false,
	})
	var row: Dictionary = NakamaSocialBackend.map_team_row(group)
	assert_eq(str(row.get("name")), "Closed Crew", "raw name fallback")
	assert_eq(str(row.get("access_mode")), "by-request", "closed group implies by-request")
	assert_eq(int(row.get("power")), 0, "no metadata means zero power")


func test_banner_recipe_from_meta_full_and_empty() -> void:
	var recipe: Dictionary = NakamaSocialBackend.banner_recipe_from_meta({
		"banner_base": "b", "banner_icon": "i", "banner_base_lut": "bl", "banner_icon_lut": "il",
		# The server stores the scale as a STRING (every banner_* value is);
		# the mapper must parse it back to a float.
		"banner_icon_scale": "1.5",
	})
	assert_eq(str(recipe.get("base")), "b", "base")
	assert_eq(str(recipe.get("icon")), "i", "icon")
	assert_eq(str(recipe.get("base_lut")), "bl", "base lut")
	assert_eq(str(recipe.get("icon_lut")), "il", "icon lut")
	assert_almost_eq(float(recipe.get("icon_scale", 0.0)), 1.5, 0.0001, "string-form scale parses to float")
	var empty: Dictionary = NakamaSocialBackend.banner_recipe_from_meta({})
	assert_eq(str(empty.get("base")), "", "missing keys become empty strings")
	assert_almost_eq(float(empty.get("icon_scale", 0.0)), 1.0, 0.0001, "a missing scale falls back to the classic size")


# --- Chat -----------------------------------------------------------------------------

func test_map_chat_message_shape() -> void:
	var message := NakamaAPI.ApiChannelMessage.create(NakamaAPI, {
		"message_id": "m-1",
		"username": "WGTJ-DMPG",
		"content": JSON.stringify({"text": "hi team"}),
		"create_time": TS_SAMPLE,
	})
	var row: Dictionary = NakamaSocialBackend.map_chat_message(message, "Ada")
	assert_eq(str(row.get("id")), "m-1", "server message id")
	assert_eq(str(row.get("sender_code")), "WGTJ-DMPG", "sender username is the code")
	assert_eq(str(row.get("sender_name")), "Ada", "resolved sender name passed through")
	assert_eq(str(row.get("text")), "hi team", "JSON wrapper unwrapped")
	var expected_ts := Time.get_unix_time_from_datetime_dict({
		"year": 2026, "month": 11, "day": 7, "hour": 19, "minute": 31, "second": 21,
	})
	assert_eq(int(row.get("ts")), int(expected_ts), "RFC3339 create_time parsed to unix seconds")


func test_message_text_plain_wrapped_and_malformed() -> void:
	assert_eq(NakamaSocialBackend.message_text("plain text"), "plain text", "plain passthrough (never parsed)")
	assert_eq(NakamaSocialBackend.message_text(JSON.stringify({"text": "wrapped"})), "wrapped", "JSON wrapper unwrapped")
	var raw := NakamaSocialBackend.message_text("{not json")
	assert_eq(raw, "{not json", "malformed content kept raw")
	# This build's JSON.parse_string logs one engine error on malformed input.
	assert_engine_error("Parse JSON failed", "malformed brace content trips the engine JSON logger")


# --- RPC / metadata payloads -------------------------------------------------------------

func test_parse_rpc_payload_valid_malformed_and_non_dict() -> void:
	var payload := JSON.stringify({"ok": true, "team_id": "g-9"})
	var parsed: Dictionary = NakamaSocialBackend.parse_rpc_payload(payload)
	assert_true(bool(parsed.get("ok")), "ok flag survives")
	assert_eq(str(parsed.get("team_id")), "g-9", "team id survives")
	var malformed := NakamaSocialBackend.parse_rpc_payload("{nope")
	assert_eq(malformed.is_empty(), true, "malformed payload -> {}")
	# This build's JSON.parse_string logs one engine error on malformed input.
	assert_engine_error("Parse JSON failed", "malformed payload trips the engine JSON logger")
	assert_eq(NakamaSocialBackend.parse_rpc_payload("42").is_empty(), true, "non-dict JSON -> {}")
	assert_eq(NakamaSocialBackend.parse_rpc_payload("").is_empty(), true, "empty payload -> {} (no parse attempt)")


func test_parse_meta_valid_and_absent() -> void:
	var meta: Dictionary = NakamaSocialBackend.parse_meta(JSON.stringify({"access_mode": "open"}))
	assert_eq(str(meta.get("access_mode")), "open", "metadata parsed")
	assert_eq(NakamaSocialBackend.parse_meta("").is_empty(), true, "absent metadata -> {} (no parse attempt)")
