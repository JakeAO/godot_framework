extends Node
## Remote configuration with A/B experiment assignment.
##
## In this prototype the "network" is a local JSON stub (res://resources/config/
## remote_config.json) so the whole pipeline (fetch -> validate -> cache ->
## bucketing -> exposure logging) runs offline and headless. Swapping in a real
## HTTP backend later only requires replacing _load_from_network().
##
## Config shape:
##   {
##     "flags":      { "<name>": bool },
##     "values":     { "<key>": <any JSON value> },
##     "experiments":{ "<name>": { "variants": { "<id>": { "weight": int, "params": {} } } } },
##     "events":     [ { ... multiplayer-surface widgets (display-only) ... } ],
##     "campaigns":  [ { ... solo-mechanic widgets: action claim/modifier/display ... } ],
##     "offers":     [ { ... offer widgets for the right zone ... } ],
##     "shop_items": [ { ... Shop catalog entries (TDD §3.20) ... } ]
##   }
## Events/campaigns may carry an optional `ends_in_hours` (deadline = fetch
## time + hours; absent/<=0 is evergreen) and a freeform `metadata` dict
## (zone / progress / dialog keys, see GDD §6).
##
## Assignment is stable per device: FNV-1a hash of "<device_id>:<experiment>"
## modulo 100, compared against cumulative variant weights.

const DEVICE_DOMAIN: String = "device"
const DEVICE_ID_KEY: String = "device_id"

var _flags: Dictionary = {}
var _values: Dictionary = {}
var _experiments: Dictionary = {}
var _events: Array[Dictionary] = []
var _campaigns: Array[Dictionary] = []
var _offers: Array[Dictionary] = []
var _shop_items: Array[Dictionary] = []
## id -> deadline unix time (-1 = evergreen). Computed at fetch/cache-load.
var _event_deadlines: Dictionary = {}
var _campaign_deadlines: Dictionary = {}
## Dev/QA variant pins (experiment_name -> variant_id); cleared on every
## config apply (TDD §3.8).
var _forced_variants: Dictionary = {}
var _device_id: String = ""
var _config_path: String = Paths.REMOTE_CONFIG_STUB_PATH
var _cache_path: String = Paths.REMOTE_CONFIG_CACHE_PATH
var _loaded: bool = false
var _exposed_this_session: Dictionary = {}


func _ready() -> void:
	# Deliberately passive: device id is persisted lazily inside fetch(), which
	# runs after SaveSystem.load_save(), so we never clobber an existing save.
	_load_from_cache()


# --- Public API ---------------------------------------------------------------

func set_config_path(path: String) -> void:
	_config_path = path


func set_cache_path(path: String) -> void:
	_cache_path = path


func set_device_id(device_id: String) -> void:
	if device_id.is_empty():
		push_warning("RemoteConfig: ignoring empty device id")
		return
	_device_id = device_id


func get_device_id() -> String:
	return _device_id


func is_loaded() -> bool:
	return _loaded


## Fetches the remote config. Mock mode (default): synchronous stub read, so all
## existing un-awaited call sites stay byte-identical. Real mode: fire-and-forget
## HTTP GET of the Caddy-served static file (TDD §3.17 — availability is
## independent of backend state); emits config_loaded/config_failed on completion.
func fetch() -> void:
	_ensure_device_id()
	if _is_real_mode():
		_fetch_http_config()
		return
	var raw: Variant = _load_from_network()
	if typeof(raw) != TYPE_DICTIONARY or not _is_valid_config(raw):
		var msg := "remote config invalid; using cached/defaults"
		push_warning("RemoteConfig: " + msg)
		EventBus.config_failed.emit(msg)
		return

	_apply_config(raw as Dictionary)

	_write_cache(raw as Dictionary)
	EventBus.config_loaded.emit()


func is_enabled(flag_name: String, default_value: bool = false) -> bool:
	var v: Variant = _flags.get(flag_name, default_value)
	return bool(v)


func get_value(key: String, default_value: Variant = null) -> Variant:
	return _values.get(key, default_value)


## Returns the stable variant id for this device, or "" if unknown/disabled.
## Dev-pinned variants (force_variant) take precedence.
func get_experiment(experiment_name: String) -> String:
	if _forced_variants.has(experiment_name):
		return str(_forced_variants[experiment_name])
	var experiment: Variant = _experiments.get(experiment_name)
	if typeof(experiment) != TYPE_DICTIONARY:
		return ""
	var variants: Variant = (experiment as Dictionary).get("variants")
	if typeof(variants) != TYPE_DICTIONARY or (variants as Dictionary).is_empty():
		return ""
	return pick_variant(variants, _device_id + ":" + experiment_name)


func get_experiment_param(experiment_name: String, param_key: String, default_value: Variant = null) -> Variant:
	var variant_id := get_experiment(experiment_name)
	if variant_id.is_empty():
		return default_value
	var experiment: Dictionary = _experiments.get(experiment_name, {})
	var variants: Dictionary = experiment.get("variants", {})
	var v: Variant = variants.get(variant_id)
	if typeof(v) != TYPE_DICTIONARY:
		return default_value
	var params: Dictionary = (v as Dictionary).get("params", {})
	return params.get(param_key, default_value)


## Emits EventBus.experiment_exposed once per experiment per session.
func log_experiment_exposure(experiment_name: String) -> void:
	if _exposed_this_session.has(experiment_name):
		return
	var variant_id := get_experiment(experiment_name)
	if variant_id.is_empty():
		return
	_exposed_this_session[experiment_name] = true
	EventBus.experiment_exposed.emit(experiment_name, variant_id)


func get_events() -> Array[Dictionary]:
	return _events.duplicate()


func get_campaigns() -> Array[Dictionary]:
	return _campaigns.duplicate()


func get_offers() -> Array[Dictionary]:
	return _offers.duplicate()


## Shop catalog (TDD §3.20): raw entry dicts in config order; the screen
## validates per-row and skips malformed entries with a warning.
func get_shop_items() -> Array[Dictionary]:
	return _shop_items.duplicate()


## Deadline unix time for a zone entry (-1 = evergreen, unknown id = -1).
func get_event_deadline(event_id: String) -> int:
	return int(_event_deadlines.get(event_id, -1))


func get_campaign_deadline(campaign_id: String) -> int:
	return int(_campaign_deadlines.get(campaign_id, -1))


## True if the entry exists and is not expired (evergreen = always active).
## Unknown ids are inactive.
func is_event_active(event_id: String) -> bool:
	return _event_deadlines.has(event_id) and _is_alive(get_event_deadline(event_id))


func is_campaign_active(campaign_id: String) -> bool:
	return _campaign_deadlines.has(campaign_id) and _is_alive(get_campaign_deadline(campaign_id))


# --- Dev/QA overrides (TDD §3.8) ------------------------------------------------
## All of these are cleared by any config apply (_apply_config): a refetch or
## cache load resets the config to its stub/cache state.

## In-memory flag override for the dev panel.
func set_flag(flag_name: String, enabled: bool) -> void:
	_flags[flag_name] = enabled


## In-memory value override for the dev panel (same lifetime as set_flag).
func set_value(key: String, value: Variant) -> void:
	_values[key] = value


## In-memory deadline override for a known event id (dev/QA + tests — same
## lifetime as set_flag; a refetch or cache load resets it).
func set_event_deadline(event_id: String, deadline_unix: int) -> void:
	if _event_deadlines.has(event_id):
		_event_deadlines[event_id] = deadline_unix


## Pins `variant_id` for `experiment_name` until the next config apply.
## Unknown experiment/variant -> warning + no-op.
func force_variant(experiment_name: String, variant_id: String) -> void:
	var experiment: Variant = _experiments.get(experiment_name)
	if typeof(experiment) != TYPE_DICTIONARY:
		push_warning("RemoteConfig: cannot force unknown experiment '%s'" % experiment_name)
		return
	var variants: Dictionary = (experiment as Dictionary).get("variants", {})
	if not variants.has(variant_id):
		push_warning("RemoteConfig: cannot force unknown variant '%s' of '%s'" % [variant_id, experiment_name])
		return
	_forced_variants[experiment_name] = variant_id


func get_flags() -> Dictionary:
	return _flags.duplicate(true)


func get_experiment_names() -> Array[String]:
	var names: Array[String] = []
	for name in _experiments.keys():
		names.append(str(name))
	names.sort()
	return names


func get_experiment_variant_ids(experiment_name: String) -> Array[String]:
	var experiment: Variant = _experiments.get(experiment_name)
	if typeof(experiment) != TYPE_DICTIONARY:
		return []
	var variants: Dictionary = (experiment as Dictionary).get("variants", {})
	var ids: Array[String] = []
	for id in variants.keys():
		ids.append(str(id))
	ids.sort()
	return ids


# --- Bucketing (pure, static: unit-testable without a singleton) ---------------

## Deterministically picks a variant id from {id: {weight: int}} for a seed.
## Weights are normalized against their sum; total 0 returns the first key.
static func pick_variant(variants: Dictionary, variant_seed: String) -> String:
	if variants.is_empty():
		return ""
	var ids: Array[String] = []
	var weights: Array[int] = []
	var total := 0
	for id in variants.keys():
		ids.append(str(id))
		var wi := 0
		if typeof(variants[id]) == TYPE_DICTIONARY:
			wi = int((variants[id] as Dictionary).get("weight", 0))
		if wi < 0:
			wi = 0
		weights.append(wi)
		total += wi
	if total <= 0:
		return ids[0]

	var bucket := (fnv1a(variant_seed) % 100 + 100) % 100
	var scaled_bucket := float(bucket) * (float(total) / 100.0)
	var cumulative := 0.0
	for i in ids.size():
		cumulative += float(weights[i])
		if scaled_bucket < cumulative:
			return ids[i]
	return ids[ids.size() - 1]


## FNV-1a 64-bit over the string's UTF-8 bytes. Fully deterministic across
## runs and platforms (unlike engine hash(), which we do not want to rely on).
const _FNV_OFFSET: int = -3750763034362895579  # 0xcbf29ce484222325 as signed i64
const _FNV_PRIME: int = 1099511628211          # 0x00000100000001b3

static func fnv1a(text: String) -> int:
	var value := _FNV_OFFSET
	for byte in text.to_utf8_buffer():
		value ^= byte
		value *= _FNV_PRIME
	return value


# --- Internals ------------------------------------------------------------------

## Shared parse for fetch() and cache load: stores sections, computes zone
## deadlines from the CURRENT time (TDD §3.8), marks the config loaded.
func _apply_config(raw: Dictionary) -> void:
	_flags = raw["flags"]  # also drops any dev set_flag() overrides
	_values = raw["values"]
	_experiments = raw["experiments"]
	_forced_variants.clear()
	_events.clear()
	_event_deadlines.clear()
	for e in raw.get("events", []):
		if typeof(e) == TYPE_DICTIONARY:
			var entry := e as Dictionary
			_events.append(entry)
			_event_deadlines[str(entry.get("id", ""))] = _deadline_for(entry)
	_campaigns.clear()
	_campaign_deadlines.clear()
	for c in raw.get("campaigns", []):
		if typeof(c) == TYPE_DICTIONARY:
			var entry := c as Dictionary
			_campaigns.append(entry)
			_campaign_deadlines[str(entry.get("id", ""))] = _deadline_for(entry)
	_offers.clear()
	for o in raw.get("offers", []):
		if typeof(o) == TYPE_DICTIONARY:
			_offers.append(o)
	_shop_items.clear()
	for s in raw.get("shop_items", []):
		if typeof(s) == TYPE_DICTIONARY:
			_shop_items.append(s)
	_loaded = true


## Deadline = now + ends_in_hours*3600; absent/<=0 hours -> evergreen (-1).
func _deadline_for(entry: Dictionary) -> int:
	var hours := int(entry.get("ends_in_hours", 0))
	if hours <= 0:
		return -1
	return Time.get_unix_time_from_system() + hours * 3600


func _is_alive(deadline: int) -> bool:
	if deadline < 0:
		return true
	return Time.get_unix_time_from_system() < deadline


func _load_from_network() -> Variant:
	# Mock-mode stub (the gate's hermetic path): reads the local config file.
	var file := FileAccess.open(_config_path, FileAccess.READ)
	if file == null:
		push_warning("RemoteConfig: cannot open %s (err %d)" % [_config_path, FileAccess.get_open_error()])
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed


## Real-mode fetch (TDD §3.17): HTTP GET <backend_base_url>/config/remote_config.json
## — a Caddy-served static file, plain HTTPS, no auth. Fire-and-forget from
## fetch(); the last-good cache covers failures (config_failed + fallback).
func _fetch_http_config() -> void:
	var base_url := str(ProjectSettings.get_setting("game/backend_base_url", "")).strip_edges()
	while base_url.ends_with("/"):
		base_url = base_url.left(base_url.length() - 1)
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var err := http.request("%s/config/remote_config.json" % base_url, PackedStringArray(["Accept: application/json"]))
	if err != OK:
		http.queue_free()
		push_warning("RemoteConfig: config request failed to start (err %d); using cached/defaults" % err)
		EventBus.config_failed.emit("config request failed to start")
		return
	var res: Array = await http.request_completed
	http.queue_free()
	var status := int(res[1])
	if status != 200:
		push_warning("RemoteConfig: config fetch HTTP %d; using cached/defaults" % status)
		EventBus.config_failed.emit("config fetch HTTP %d" % status)
		return
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not _is_valid_config(parsed):
		push_warning("RemoteConfig: remote config invalid; using cached/defaults")
		EventBus.config_failed.emit("remote config invalid; using cached/defaults")
		return
	_apply_config(parsed as Dictionary)
	_write_cache(parsed as Dictionary)
	EventBus.config_loaded.emit()


static func _is_real_mode() -> bool:
	return not str(ProjectSettings.get_setting("game/backend_base_url", "")).is_empty()


func _is_valid_config(raw: Dictionary) -> bool:
	for section in ["flags", "values", "experiments"]:
		if typeof(raw.get(section)) != TYPE_DICTIONARY:
			return false
	for exp_name in raw["experiments"].keys():
		var experiment: Variant = raw["experiments"][exp_name]
		if typeof(experiment) != TYPE_DICTIONARY or typeof((experiment as Dictionary).get("variants")) != TYPE_DICTIONARY:
			return false
	return true


func _write_cache(raw: Dictionary) -> void:
	var file := FileAccess.open(_cache_path, FileAccess.WRITE)
	if file == null:
		push_warning("RemoteConfig: cannot write cache %s (err %d)" % [_cache_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(raw, "\t"))
	file.close()


func _load_from_cache() -> void:
	var file := FileAccess.open(_cache_path, FileAccess.READ)
	if file == null:
		return  # First launch: defaults until Main calls fetch().
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or not _is_valid_config(parsed):
		push_warning("RemoteConfig: corrupt cache; keeping defaults")
		return
	_apply_config(parsed as Dictionary)


func _ensure_device_id() -> void:
	var existing: Variant = SaveSystem.get_value(DEVICE_DOMAIN, DEVICE_ID_KEY, "")
	if not str(existing).is_empty():
		_device_id = str(existing)
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_device_id = "dev_" + _to_hex(rng.randi()) + _to_hex(rng.randi())
	SaveSystem.set_value(DEVICE_DOMAIN, DEVICE_ID_KEY, _device_id)
	SaveSystem.save_game()


func _to_hex(value: int) -> String:
	var hex_chars := "0123456789abcdef"
	var out := ""
	for i in 8:
		out = hex_chars[value & 0xF] + out
		value >>= 4
	return out
