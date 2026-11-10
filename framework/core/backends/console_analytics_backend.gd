class_name ConsoleAnalyticsBackend
extends IAnalyticsBackend
## Prints events to stdout. Useful for development and headless runs.


func flush(events: Array[Dictionary]) -> void:
	for e in events:
		print("[analytics] ", e.get("name"), " ", JSON.stringify(e.get("properties", {})))
