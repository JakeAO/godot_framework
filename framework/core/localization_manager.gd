extends Node
## Runtime localization on top of Godot's TranslationServer (.po files are
## registered in project.godot and auto-loaded at boot).
##
## Usage in scripts:  tr("key")            (static call, always current)
## In scenes: rebuild/refresh labels when `locale_applied` fires.

const SUPPORTED_LANGUAGES: Array[String] = ["en", "es"]

signal locale_applied(language_code: String)


func _ready() -> void:
	SettingsManager.language_changed.connect(_on_language_requested)


func init() -> void:
	apply_locale(SettingsManager.get_language())


func get_current_locale() -> String:
	return TranslationServer.get_locale()


func set_language(language_code: String) -> void:
	# Routes through SettingsManager so the choice persists.
	if not SUPPORTED_LANGUAGES.has(language_code.to_lower()):
		push_warning("LocalizationManager: unsupported language '%s'; keeping '%s'" % [language_code, get_current_locale()])
		return
	SettingsManager.set_language(language_code)


func apply_locale(language_code: String) -> void:
	var lc := language_code.to_lower().strip_edges()
	if not TranslationServer.get_loaded_locales().has(lc):
		push_warning("LocalizationManager: no translation registered for '%s'" % lc)
		return
	TranslationServer.set_locale(lc)
	locale_applied.emit(lc)


func is_supported(language_code: String) -> bool:
	return SUPPORTED_LANGUAGES.has(language_code.to_lower())


func _on_language_requested(language_code: String) -> void:
	if not is_supported(language_code):
		push_warning("LocalizationManager: settings requested unsupported language '%s'" % language_code)
		return
	apply_locale(language_code)
