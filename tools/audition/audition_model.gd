class_name AuditionModel
extends RefCounted
## Data side of the take-picking tool: the generated takes per sound (best score first), the
## use / skip decisions and the _pick folders that tools/audio/process.py turns into game files.
##   <root>/_raw/<key>/<file>.wav + ranking.json   the generated takes (rank.py)
##   <root>/_pick/<key>/<file>.wav                 a copy of every take marked "use"
##   <root>/_pick/decisions.json                   "<key>/<file>" -> "use" | "skip"

const USE := "use"
const SKIP := "skip"

var root := ""
var keys: Array[String] = []
var takes: Dictionary = {}  ## key -> Array of {file, score, onset_s, events, centroid_hz}
var decisions: Dictionary = {}


func _init(audio_root: String) -> void:
	root = audio_root


## `order` is the preferred order of the sound keys (the catalog order); other folders follow.
func load_all(order: Array) -> void:
	keys.clear()
	takes.clear()
	var found := DirAccess.get_directories_at(root.path_join("_raw"))
	for key in order:
		if str(key) in found:
			keys.append(str(key))
	for key in found:
		if not keys.has(key):
			keys.append(key)
	for key in keys:
		takes[key] = _read_takes(key)
	decisions.clear()
	var path := root.path_join("_pick/decisions.json")
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			decisions = parsed


func raw_path(key: String, file: String) -> String:
	return root.path_join("_raw").path_join(key).path_join(file)


func decision(key: String, file: String) -> String:
	return str(decisions.get(key + "/" + file, ""))


## value: USE, SKIP or "" (undecided). Keeps the _pick folder and decisions.json in step.
func set_decision(key: String, file: String, value: String) -> void:
	if value == "":
		decisions.erase(key + "/" + file)
	else:
		decisions[key + "/" + file] = value
	var copy := root.path_join("_pick").path_join(key).path_join(file)
	if value == USE:
		DirAccess.make_dir_recursive_absolute(copy.get_base_dir())
		DirAccess.copy_absolute(raw_path(key, file), copy)
	elif FileAccess.file_exists(copy):
		DirAccess.remove_absolute(copy)
	DirAccess.make_dir_recursive_absolute(root.path_join("_pick"))
	var f := FileAccess.open(root.path_join("_pick/decisions.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(decisions, "  "))


## {use, skip, open} for one sound, or for all sounds when key is "".
func counts(key: String = "") -> Dictionary:
	var out := {USE: 0, SKIP: 0, "open": 0}
	for k in (keys if key == "" else [key]):
		for t in takes.get(k, []):
			var d := decision(k, t["file"])
			out[d if d != "" else "open"] += 1
	return out


func _read_takes(key: String) -> Array:
	var rows := {}
	var rank_path := root.path_join("_raw").path_join(key).path_join("ranking.json")
	if FileAccess.file_exists(rank_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(rank_path))
		if parsed is Array:
			for r in parsed:
				rows[str(r["file"])] = r
	var out: Array = []
	for file in DirAccess.get_files_at(root.path_join("_raw").path_join(key)):
		if file.get_extension().to_lower() != "wav":
			continue
		var r: Dictionary = rows.get(file, {})
		out.append({"file": file, "score": float(r.get("score", 0.0)), "onset_s": r.get("onset_s", 0.0),
				"events": r.get("events", 0), "centroid_hz": r.get("centroid_hz", 0)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"] if a["score"] != b["score"] else a["file"] < b["file"])
	return out
