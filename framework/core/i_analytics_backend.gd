extends RefCounted
class_name IAnalyticsBackend
## Interface for analytics sinks. Implement flush() to receive a batch of
## normalized event dictionaries: {name, ts, session_id, properties}.


func flush(_events: Array[Dictionary]) -> void:
	pass
