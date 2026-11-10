extends Node
## Player identity (TDD §3.16/§3.17): a stable random 256-bit key, generated once on
## first launch and persisted in its OWN file — deliberately outside
## save.json so it survives "Reset Save Data" and corrupt-save quarantine.
## v2 (D5b.2) also persists the Nakama session JWT next to the key: real mode
## (game/backend_base_url non-empty) sends it as a bearer via get_auth_headers();
## mock mode keeps the raw-key header unchanged. The token seam contract holds:
## callers never change when the credential format does.

const KEY_LENGTH_BYTES: int = 32
## Fixed word list for player codes; FNV-1a(key) % size picks the word.
const CODE_WORDS: Array[String] = [
	"OWL", "FOX", "HAWK", "MOSS", "RIVER", "STORM", "CLOUD", "STONE",
	"MAPLE", "WOLF", "TIDE", "SPARK", "REEF", "DUNE", "FERN", "PINE",
]

var _identity_path: String = Paths.PLAYER_IDENTITY_PATH
var _player_key: String = ""
var _session_token: String = ""
var _session_expires_at: int = 0


func _ready() -> void:
	_load_or_create()


# --- Public API ---------------------------------------------------------------

## Redirects the identity file and reloads (tests use a gut_tmp path).
func set_identity_path(path: String) -> void:
	_identity_path = path
	_player_key = ""
	_session_token = ""
	_session_expires_at = 0
	_load_or_create()


func get_identity_path() -> String:
	return _identity_path


func get_player_key() -> String:
	if _player_key.is_empty():
		_load_or_create()
	return _player_key


## Short human-readable identifier derived DETERMINISTICALLY from the key, so
## any device holding the key computes the same code with no server round-trip.
func get_player_code() -> String:
	return derive_player_code(get_player_key())


static func derive_player_code(player_key: String) -> String:
	var word_index := (RemoteConfig.fnv1a(player_key) % CODE_WORDS.size() + CODE_WORDS.size()) % CODE_WORDS.size()
	var number := (RemoteConfig.fnv1a(player_key + ":code") % 10000 + 10000) % 10000
	return "%s-%04d" % [CODE_WORDS[word_index], number]


## THE TOKEN SEAM: v1 sends the raw key; v2 (TDD §3.17) sends the persisted
## Nakama JWT as a bearer in real mode. Callers never change when the
## credential format does.
func get_auth_headers() -> Dictionary:
	if _is_real_mode():
		var session := get_stored_session()
		if not session.is_empty():
			return {"Authorization": "Bearer %s" % str(session.get("token", ""))}
	return {"X-Player-Key": get_player_key()}


# --- Session persistence (TDD §3.17, v2) -------------------------------------------

## The stored Nakama session {token: String, expires_at: int}, or {} when none
## is stored or it has expired. The JWT lives in the identity file (NOT
## save.json) so it survives reset-save/quarantine like the key itself.
func get_stored_session() -> Dictionary:
	if _session_token.is_empty():
		return {}
	if _session_expires_at <= int(Time.get_unix_time_from_system()):
		return {}
	return {"token": _session_token, "expires_at": _session_expires_at}


## Persists the session and writes it next to the key in the identity file.
func set_session(token: String, expires_at: int) -> void:
	_session_token = token
	_session_expires_at = expires_at
	_persist()


## Drops the stored session (e.g. after a terminal auth failure).
func clear_session() -> void:
	_session_token = ""
	_session_expires_at = 0
	_persist()


# --- Internals ------------------------------------------------------------------

static func _is_real_mode() -> bool:
	return not str(ProjectSettings.get_setting("game/backend_base_url", "")).is_empty()

func _load_or_create() -> void:
	var file := FileAccess.open(_identity_path, FileAccess.READ)
	if file != null:
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			var data := parsed as Dictionary
			var key := str(data.get("key", ""))
			if _is_valid_key(key):
				_player_key = key
				_session_token = str(data.get("session_token", ""))
				_session_expires_at = int(data.get("expires_at", 0))
				return
		push_warning("IdentityService: identity file invalid; generating a new player key")
	_player_key = _generate_key()
	_persist()


func _is_valid_key(key: String) -> bool:
	if key.length() != KEY_LENGTH_BYTES * 2:
		return false
	for c in key:
		if not ("0" <= c and c <= "9") and not ("a" <= c and c <= "f"):
			return false
	return true


func _generate_key() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var out := ""
	for i in KEY_LENGTH_BYTES / 4:
		out += _to_hex(rng.randi())
	return out


func _persist() -> void:
	var file := FileAccess.open(_identity_path, FileAccess.WRITE)
	if file == null:
		push_warning("IdentityService: cannot write %s (err %d)" % [_identity_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify({
		"key": _player_key,
		"session_token": _session_token,
		"expires_at": _session_expires_at,
	}, "\t"))
	file.close()


func _to_hex(value: int) -> String:
	var hex_chars := "0123456789abcdef"
	var out := ""
	for i in 8:
		out = hex_chars[value & 0xF] + out
		value >>= 4
	return out
