class_name FileAnalyticsBackend
extends IAnalyticsBackend
## Appends events as JSON lines to a local file (prototype data sink).


func _init(path: String = Paths.ANALYTICS_LOG_PATH) -> void:
	_path = path

var _path: String


func flush(events: Array[Dictionary]) -> void:
	var file := FileAccess.open(_path, FileAccess.WRITE_READ)
	if file == null:
		push_error("FileAnalyticsBackend: cannot open %s (err %d)" % [_path, FileAccess.get_open_error()])
		return
	file.seek_end(0)
	for e in events:
		file.store_line(JSON.stringify(e))
	file.close()
