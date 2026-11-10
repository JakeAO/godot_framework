class_name MockSaveSyncBackend
extends ISaveSyncBackend
## No-op success stand-in for the cloud-save transport (TDD §3.16): local-only
## behavior, today's default. Uploads are recorded so tests can assert sync
## activity without a server.

var uploads: Array[Dictionary] = []


func fetch_synced_domains() -> Dictionary:
	return {"domains": {}, "fetched_at": Time.get_unix_time_from_system()}


func upload_synced_domains(domains: Dictionary) -> bool:
	uploads.append(domains.duplicate(true))
	return true
