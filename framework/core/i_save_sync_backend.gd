extends RefCounted
class_name ISaveSyncBackend
## Interface for the cloud-save transport (TDD §3.16). Domains travel as
## {name: {data: Dictionary, updated_at: int}}; fetch returns
## {domains: {...}, fetched_at: int}.

func fetch_synced_domains() -> Dictionary:
	return {"domains": {}, "fetched_at": 0}


func upload_synced_domains(_domains: Dictionary) -> bool:
	return true
