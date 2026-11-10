extends Node
## Central registry for all filesystem paths used by the framework.
## Keeps hard-coded paths out of feature scripts (see AGENTS.md).

const SAVE_PATH: String = "user://save.json"
const PLAYER_IDENTITY_PATH: String = "user://player_identity.json"
const ANALYTICS_LOG_PATH: String = "user://analytics.jsonl"
const REMOTE_CONFIG_CACHE_PATH: String = "user://remote_config_cache.json"
const CORRUPT_SAVE_SUFFIX: String = ".corrupt"

const REMOTE_CONFIG_STUB_PATH: String = "res://resources/config/remote_config.json"

const AUDIO_TRACKS_DIR: String = "res://assets/audio/"
const TRANSLATIONS_DIR: String = "res://assets/translations/"

const STAGES_DIR: String = "res://resources/stages/"


func user_dir() -> String:
	return OS.get_user_data_dir()


func ensure_user_dir() -> void:
	var dir := DirAccess.open(user_dir())
	if dir == null:
		push_error("Paths: could not open user dir %s (err %d)" % [user_dir(), DirAccess.get_open_error()])
