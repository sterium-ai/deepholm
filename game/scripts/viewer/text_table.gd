extends RefCounted

## Loads the keyed player-facing string table for one locale
## (data/text/<locale>.json) on top of the English table (data/text/en.json),
## so UI scripts look up text by string id instead of hard-coding literals and
## a key the locale lacks still shows its English text. en.json is the
## complete key set; another locale may hold any subset of it. The core
## returns reason codes and parameters only (ADR 052): this is where they
## become words.

const FALLBACK_LOCALE := "en"
const DEFAULT_TEXT_DIR := "res://data/text"

## The locale whose file was loaded; FALLBACK_LOCALE when the requested one
## has no file.
var locale: String = FALLBACK_LOCALE

var _strings: Dictionary = {}
var _fallback: Dictionary = {}

func _init(requested_locale: String = FALLBACK_LOCALE, text_dir: String = DEFAULT_TEXT_DIR) -> void:
	_fallback = _load(text_dir.path_join(FALLBACK_LOCALE + ".json"))
	if requested_locale == FALLBACK_LOCALE or requested_locale.is_empty():
		return
	var path := text_dir.path_join(requested_locale + ".json")
	if not FileAccess.file_exists(path):
		return
	_strings = _load(path)
	locale = requested_locale

## The locale the viewer asks for: a "--locale=<code>" user argument (after
## "--" on the Godot command line), else the OS language. A locale with no
## file falls back to English in _init().
static func requested_locale() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--locale="):
			return arg.substr("--locale=".length())
	return OS.get_locale_language()

static func _load(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("ViewerTextTable: failed to open '%s'" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	push_error("ViewerTextTable: '%s' did not contain a JSON object" % path)
	return {}

## Every key of the English table, which every other locale falls back to.
func keys() -> Array:
	return _fallback.keys()

func has_string(key: String) -> bool:
	return _strings.has(key) or _fallback.has(key)

func get_string(key: String) -> String:
	if _strings.has(key):
		return String(_strings[key])
	if _fallback.has(key):
		return String(_fallback[key])
	push_warning("ViewerTextTable: missing key '%s'" % key)
	return key

## Positional "%s"/"%d" arguments.
func format(key: String, args: Array) -> String:
	return get_string(key) % args

## Named "{name}" placeholders, filled from a code-and-values Dictionary such as
## a command rejection's "params".
func format_named(key: String, params: Dictionary) -> String:
	return get_string(key).format(params)
