class_name NakamaSaveSyncBackend
extends ISaveSyncBackend
## Real ISaveSyncBackend on Nakama storage objects (TDD §3.17): collection
## "save", key = domain name, value JSON {data, updated_at}. Verified semantics
## baked in (NOTES.md): permission_read=1 (0 is invisible to ALL client reads),
## read ids must carry the caller's explicit user_id, value must be a JSON
## string. The per-domain LWW merge stays CLIENT-side in SaveSystem — Nakama's
## CAS version is not used for merge decisions.

const SAVE_COLLECTION: String = "save"

var _client: NakamaClient


func _init(client: NakamaClient) -> void:
	_client = client


func fetch_synced_domains() -> Dictionary:
	var session := OnlineService.get_session()
	if session == null:
		return {"domains": {}, "fetched_at": 0}
	var read_ids: Array = []
	for domain_name in SaveSystem.SYNCED_DOMAINS:
		read_ids.append(NakamaStorageObjectId.new(SAVE_COLLECTION, domain_name, session.user_id))
	var objects: NakamaAPI.ApiStorageObjects = await _client.read_storage_objects_async(session, read_ids)
	if objects.is_exception():
		return {"domains": {}, "fetched_at": 0}
	var domains := {}
	if objects.objects != null:
		for obj in objects.objects:
			var stored: Variant = JSON.parse_string(str((obj as NakamaAPI.ApiStorageObject).value))
			if typeof(stored) != TYPE_DICTIONARY:
				continue
			var data: Variant = (stored as Dictionary).get("data", null)
			if typeof(data) != TYPE_DICTIONARY:
				continue
			domains[str((obj as NakamaAPI.ApiStorageObject).key)] = {
				"data": data,
				"updated_at": int((stored as Dictionary).get("updated_at", 0)),
			}
	return {"domains": domains, "fetched_at": int(Time.get_unix_time_from_system())}


func upload_synced_domains(domains: Dictionary) -> bool:
	var session := OnlineService.get_session()
	if session == null:
		return false
	var writes: Array = []
	for domain_name in domains:
		var entry: Variant = domains[domain_name]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var value := JSON.stringify({"data": (entry as Dictionary).get("data", {}), "updated_at": int((entry as Dictionary).get("updated_at", 0))})
		writes.append(NakamaWriteStorageObject.new(SAVE_COLLECTION, str(domain_name), 1, 0, value, ""))
	if writes.is_empty():
		return true
	var acks: NakamaAPI.ApiStorageObjectAcks = await _client.write_storage_objects_async(session, writes)
	return not acks.is_exception()
