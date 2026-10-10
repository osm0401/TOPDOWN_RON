class_name JsonData
extends RefCounted
## Loads tuning/config JSON files from res://data.


static func load_dict(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("JsonData: cannot open %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("JsonData: %s is not a JSON object" % path)
	return {}
