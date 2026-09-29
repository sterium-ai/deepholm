extends RefCounted

## Loads a keyed English string table (see data/text/en.json) so UI scripts
## look up player-facing text by string id instead of hard-coding literals.

var _strings: Dictionary = {}

func _init(path: String = "res://data/text/en.json") -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("ViewerTextTable: failed to open '%s'" % path)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_strings = parsed
	else:
		push_error("ViewerTextTable: '%s' did not contain a JSON object" % path)

func get_string(key: String) -> String:
	if _strings.has(key):
		return String(_strings[key])
	push_warning("ViewerTextTable: missing key '%s'" % key)
	return key

func format(key: String, args: Array) -> String:
	return get_string(key) % args
