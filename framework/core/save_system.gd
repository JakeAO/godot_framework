extends Node
## Versioned JSON save persistence with atomic writes and schema migrations.
##
## Save file shape:
##   { "version": <int>, "domains": { "<domain>": { ... }, ... },
##     "sync_stamps": { "<domain>": <unix ts> } }  # optional, sync bookkeeping
##
## Domains keep feature data isolated (profile, device, settings, meta...).
## Migrations are registered as entries of {from_version:int, to_version:int,
## migration: Callable(domains: Dictionary) -> Dictionary} and run in order on load.
##
## Cross-device sync (TDD §3.16): an optional ISaveSyncBackend attached via
## set_sync_backend() uploads SYNCED_DOMAINS (debounced after saves) and
## merges fetched domains per-domain last-write-wins by updated_at stamp.

const SAVE_VERSION: int = 1
## Domains synced across devices (GDD §8); everything else stays local-only.
const SYNCED_DOMAINS: Array[String] = ["profile", "piggy_bank", "campaign_claims", "team", "shop", "gift_pile", "tournaments"]
const _SYNC_DEBOUNCE_SEC: float = 1.0

signal save_loaded(version: int)
signal save_saved(version: int)
signal save_failed(error_string: String)
signal save_cleared

var _save_path: String = Paths.SAVE_PATH
var _data: Dictionary = {}
var _migrations: Array[Dictionary] = []
var _loaded: bool = false
var _sync_backend: ISaveSyncBackend = null
var _sync_upload_scheduled: bool = false
## Which backend instance the pending upload belongs to; a stale timer firing
## after a backend swap must no-op (test isolation + swap safety).
var _sync_upload_scheduled_for: ISaveSyncBackend = null


func _ready() -> void:
	_register_default_migrations()
	save_saved.connect(_on_save_saved_for_sync)


# --- Public API ---------------------------------------------------------------

func set_save_path(path: String) -> void:
	_save_path = path


func get_save_path() -> String:
	return _save_path


func load_save() -> bool:
	_data = {}
	var file := FileAccess.open(_save_path, FileAccess.READ)
	if file == null:
		# First launch (or missing file): start fresh. Not an error.
		_data = _default_data()
		_loaded = true
		return true

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		_quarantine_corrupt_save("save file is not a JSON dictionary")
		_data = _default_data()
		_loaded = true
		save_failed.emit("unparseable save; started fresh (corrupt copy kept)")
		return false

	var disk_version: int = int(parsed.get("version", 1))
	var domains: Dictionary = parsed.get("domains", {})
	if typeof(domains) != TYPE_DICTIONARY:
		_quarantine_corrupt_save("save 'domains' is not a dictionary")
		_data = _default_data()
		_loaded = true
		save_failed.emit("malformed save; started fresh (corrupt copy kept)")
		return false

	var migrated: bool = _run_migrations(domains, disk_version)
	if not migrated:
		return false

	var stamps: Variant = parsed.get("sync_stamps", {})
	if typeof(stamps) != TYPE_DICTIONARY:
		stamps = {}
	_data = {"version": SAVE_VERSION, "domains": domains, "sync_stamps": stamps}
	_loaded = true
	save_loaded.emit(SAVE_VERSION)
	return true


func save_game() -> bool:
	if not _loaded and FileAccess.file_exists(_save_path):
		push_warning("SaveSystem.save_game(): called before load_save() while a save file exists; write skipped to protect existing data")
		return false
	_data["version"] = SAVE_VERSION
	var text := JSON.stringify(_data, "\t")
	var tmp_path := _save_path + ".tmp"

	var dir := DirAccess.open(_dir_of(_save_path))
	if dir == null:
		var err := error_string(DirAccess.get_open_error())
		save_failed.emit("cannot open save dir: " + err)
		push_error("SaveSystem: cannot open save dir for %s (%s)" % [_save_path, err])
		return false

	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		var err := error_string(FileAccess.get_open_error())
		save_failed.emit("cannot open temp save file: " + err)
		push_error("SaveSystem: cannot write %s (%s)" % [tmp_path, err])
		return false
	file.store_string(text)
	file.close()

	# Atomic swap: rename over the real file. POSIX rename is atomic.
	# (Static call: calling it on the DirAccess instance triggers a lint warning.)
	var rename_err := DirAccess.rename_absolute(tmp_path, _save_path)
	if rename_err != OK:
		save_failed.emit("atomic rename failed (err %d)" % rename_err)
		push_error("SaveSystem: rename %s -> %s failed (err %d)" % [tmp_path, _save_path, rename_err])
		return false

	save_saved.emit(SAVE_VERSION)
	return true


func get_domain(domain: String) -> Dictionary:
	var d: Variant = _data.get("domains", {}).get(domain, {})
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("SaveSystem: domain '%s' is not a dictionary; returning empty" % domain)
		return {}
	return d.duplicate(true)


func set_domain(domain: String, payload: Dictionary) -> void:
	if typeof(_data.get("domains")) != TYPE_DICTIONARY:
		_data["domains"] = {}
	_data["domains"][domain] = payload.duplicate(true)
	if SYNCED_DOMAINS.has(domain):
		_stamp_store()[domain] = int(Time.get_unix_time_from_system())


func get_value(domain: String, key: String, default_value: Variant = null) -> Variant:
	return get_domain(domain).get(key, default_value)


func set_value(domain: String, key: String, value: Variant) -> void:
	var d := get_domain(domain)
	d[key] = value
	set_domain(domain, d)


func clear_save() -> void:
	if not _loaded and FileAccess.file_exists(_save_path):
		push_warning("SaveSystem.clear_save(): called before load_save(); ignored to protect existing data")
		return
	_data = _default_data()
	var file := FileAccess.open(_save_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_data, "\t"))
		file.close()
	save_cleared.emit()


func has_saved_game() -> bool:
	return FileAccess.file_exists(_save_path)


# --- Cross-device sync (TDD §3.16) ---------------------------------------------

## Swap point (TDD §9): attach the cloud-save transport. null = local-only
## behavior (all sync entry points become no-ops).
func set_sync_backend(backend: ISaveSyncBackend) -> void:
	_sync_backend = backend


## Debounced upload of the synced domains. Every save_game() schedules one
## (when a backend is attached); saves inside the debounce window collapse
## into the pending upload, which reads the latest state when it fires.
func request_sync() -> void:
	if _sync_backend == null or not _loaded:
		return
	if _sync_upload_scheduled and _sync_upload_scheduled_for == _sync_backend:
		return
	_sync_upload_scheduled = true
	_sync_upload_scheduled_for = _sync_backend
	get_tree().create_timer(_SYNC_DEBOUNCE_SEC).timeout.connect(_do_sync_upload)


## Fetch remote domains and merge them in per-domain last-write-wins by
## updated_at stamp (GDD §8). The local save stays authoritative between
## syncs; the result surfaces via EventBus.save_sync_completed.
func fetch_synced_domains() -> void:
	if _sync_backend == null or not _loaded:
		return
	var result: Variant = await _sync_backend.fetch_synced_domains()
	if typeof(result) != TYPE_DICTIONARY:
		EventBus.save_sync_completed.emit(false)
		return
	var fetched: Variant = (result as Dictionary).get("domains", {})
	if typeof(fetched) != TYPE_DICTIONARY:
		EventBus.save_sync_completed.emit(false)
		return
	var domains := fetched as Dictionary
	var changed_domains: Array[String] = []
	for domain_name in SYNCED_DOMAINS:
		var entry: Variant = domains.get(domain_name, null)
		if entry == null or typeof(entry) != TYPE_DICTIONARY:
			continue
		var data: Variant = (entry as Dictionary).get("data", {})
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var remote_stamp := int((entry as Dictionary).get("updated_at", 0))
		if remote_stamp <= _domain_stamp(domain_name):
			continue  # local write is newer (or equal): LWW keeps it
		_data["domains"][domain_name] = (data as Dictionary).duplicate(true)
		_stamp_store()[domain_name] = remote_stamp
		changed_domains.append(domain_name)
	if changed_domains.is_empty():
		EventBus.save_sync_completed.emit(true)
		return
	save_game()  # persists merged data + stamps (also schedules an echo upload)
	for domain_name in changed_domains:
		if domain_name == "profile":
			EventBus.profile_updated.emit(get_domain("profile"))
	EventBus.save_sync_completed.emit(true)


# --- Migrations ---------------------------------------------------------------

func register_migration(from_version: int, to_version: int, migration_func: Callable) -> void:
	assert(migration_func.is_valid(), "SaveSystem: migration callable must be valid")
	_migrations.append({
		"from_version": from_version,
		"to_version": to_version,
		"migration": migration_func,
	})
	_migrations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["from_version"]) < int(b["from_version"]))


func _register_default_migrations() -> void:
	# Future migrations go here, e.g.:
	# register_migration(1, 2, Callable(self, "_migrate_1_to_2"))
	pass


func _run_migrations(domains: Dictionary, disk_version: int) -> bool:
	if disk_version > SAVE_VERSION:
		var msg := "save version %d is newer than supported %d" % [disk_version, SAVE_VERSION]
		_quarantine_corrupt_save(msg)
		save_failed.emit(msg + "; started fresh (corrupt copy kept)")
		return false

	var current := disk_version
	for m in _migrations:
		if int(m["from_version"]) == current and int(m["to_version"]) == current + 1:
			var result: Variant = m["migration"].call(domains)
			if typeof(result) != TYPE_DICTIONARY:
				var msg := "migration %d->%d returned non-dictionary" % [current, current + 1]
				_quarantine_corrupt_save(msg)
				save_failed.emit(msg + "; started fresh (corrupt copy kept)")
				return false
			domains = result
			current += 1
	if current != SAVE_VERSION:
		var msg := "no migration path from version %d to %d" % [current, SAVE_VERSION]
		push_error("SaveSystem: " + msg)
		save_failed.emit(msg)
		return false
	return true


# --- Internals ------------------------------------------------------------------

func _default_data() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"domains": {
			"profile": _default_profile(),
			"device": {},
			"settings": {},
			"meta": {
				"created_at": int(Time.get_unix_time_from_system()),
				"last_played_at": 0,
			},
		},
	}


func _default_profile() -> Dictionary:
	return {
		"name": "Player",
		"level": 1,
		"xp": 0,
		"coins": 0,
		"gems": 0,
		"best_score": 0,
		"total_games": 0,
		"last_daily_claim_day": "",
		"daily_gift_watches_count": 0,
		"daily_gift_watches_date": "",
		"streak_days": 0,
		"streak_last_date": "",
		"streak_rounds_today": 0,
		"streak_date": "",
		"streak_recovered": false,
	}


func _dir_of(path: String) -> String:
	var idx := path.rfind("/")
	if idx <= 0:
		return "."
	return path.substr(0, idx + 1)


# --- Sync internals ---------------------------------------------------------------

## Per-domain last-write-wins stamps, persisted inside the save file.
## NOTE: must assign back into _data when creating — a .get() default dict is
## a throwaway that would silently swallow stamp writes.
func _stamp_store() -> Dictionary:
	if not _data.has("sync_stamps") or typeof(_data["sync_stamps"]) != TYPE_DICTIONARY:
		_data["sync_stamps"] = {}
	return _data["sync_stamps"]


func _domain_stamp(domain: String) -> int:
	return int(_stamp_store().get(domain, 0))


## Auto-hook: every save schedules a debounced upload (no-op without backend).
func _on_save_saved_for_sync(_version: int) -> void:
	request_sync()


func _do_sync_upload() -> void:
	var backend := _sync_upload_scheduled_for
	_sync_upload_scheduled = false
	_sync_upload_scheduled_for = null
	if backend == null or not is_instance_valid(backend) or backend != _sync_backend:
		return  # stale timer: the backend was swapped since scheduling
	if not _loaded:
		return
	var ok := bool(await backend.upload_synced_domains(_build_sync_payload()))
	EventBus.save_sync_completed.emit(ok)


func _build_sync_payload() -> Dictionary:
	var payload: Dictionary = {}
	for domain_name in SYNCED_DOMAINS:
		payload[domain_name] = {"data": get_domain(domain_name), "updated_at": _domain_stamp(domain_name)}
	return payload


func _quarantine_corrupt_save(reason: String) -> void:
	push_error("SaveSystem: quarantining corrupt save (%s)" % reason)
	if not FileAccess.file_exists(_save_path):
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("-", "_").replace(" ", "_")
	var backup := _save_path + Paths.CORRUPT_SAVE_SUFFIX + "_" + stamp
	var err := DirAccess.rename_absolute(_save_path, backup)
	if err != OK:
		push_warning("SaveSystem: could not quarantine corrupt save (err %d); it will be overwritten" % err)
