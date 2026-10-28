class_name SaveJsonInts
extends RefCounted

## Exact 64-bit integers for SaveIO.read(): JSON.parse_string() returns every number as a
## float, so the seed and RNG fields are re-read from their raw tokens in the wire text.

## Full RFC 8259 number grammar, so "1e3" or "1.5" is never misread from a digit prefix.
const _JSON_NUMBER_PATTERN := "-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"

const _INT64_MAX_DIGITS := "9223372036854775807"

const _INT64_MIN_MAGNITUDE_DIGITS := "9223372036854775808"

## Re-reads "rng"."seed"/"state" from their raw tokens inside the located "state" object
## (structural, never a text search, so other same-named keys and \uXXXX-escaped keys are
## handled). Fails closed with {"ok": false} -- never the lossy float -- for a fractional,
## out-of-int64 or unlocatable token.
static func _restore_exact_rng(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not (state.get("rng") is Dictionary):
		return {"ok": true}
	var rng: Dictionary = state["rng"]
	if not rng.has("seed") and not rng.has("state"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("rng"):
		return {"ok": false, "message": "rng could not be structurally located in the save's raw JSON"}
	var rng_span: Dictionary = (located_state["members"] as Dictionary)["rng"]
	var text: String = located_state["text"]
	var rng_start: int = rng_span["start"]
	if rng_start >= text.length() or text[rng_start] != "{":
		return {"ok": false, "message": "rng is not an object in the save's raw JSON"}
	var rng_members := _scan_object_members(text, rng_start + 1)
	if not rng_members.has("__end__"):
		return {"ok": false, "message": "rng object could not be structurally parsed from the save's raw JSON"}
	for key in ["seed", "state"]:
		if not rng.has(key):
			continue
		if not rng_members.has(key):
			return {"ok": false, "message": "rng.%s could not be structurally located in the save's raw JSON" % key}
		var span: Dictionary = rng_members[key]
		var token := text.substr(span["start"], span["end"] - span["start"])
		var parsed := _parse_json_integer_token(token)
		if not parsed["ok"]:
			return {"ok": false, "message": "rng.%s is not a supported 64-bit integer" % key}
		rng[key] = parsed["value"]
	return {"ok": true}

## Same for "incidentScheduler"."rng" (its RNG state easily exceeds 2^53), one level deeper.
static func _restore_exact_incident_rng(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not (state.get("incidentScheduler") is Dictionary):
		return {"ok": true}
	var incident_scheduler: Dictionary = state["incidentScheduler"]
	if not (incident_scheduler.get("rng") is Dictionary):
		return {"ok": true}
	var rng: Dictionary = incident_scheduler["rng"]
	if not rng.has("seed") and not rng.has("state"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("incidentScheduler"):
		return {"ok": false, "message": "incidentScheduler could not be structurally located in the save's raw JSON"}
	var text: String = located_state["text"]
	var incident_span: Dictionary = (located_state["members"] as Dictionary)["incidentScheduler"]
	var incident_start: int = incident_span["start"]
	if incident_start >= text.length() or text[incident_start] != "{":
		return {"ok": false, "message": "incidentScheduler is not an object in the save's raw JSON"}
	var incident_members := _scan_object_members(text, incident_start + 1)
	if not incident_members.has("__end__") or not incident_members.has("rng"):
		return {"ok": false, "message": "incidentScheduler.rng could not be structurally located in the save's raw JSON"}
	var rng_span: Dictionary = incident_members["rng"]
	var rng_start: int = rng_span["start"]
	if rng_start >= text.length() or text[rng_start] != "{":
		return {"ok": false, "message": "incidentScheduler.rng is not an object in the save's raw JSON"}
	var rng_members := _scan_object_members(text, rng_start + 1)
	if not rng_members.has("__end__"):
		return {"ok": false, "message": "incidentScheduler.rng object could not be structurally parsed from the save's raw JSON"}
	for key in ["seed", "state"]:
		if not rng.has(key):
			continue
		if not rng_members.has(key):
			return {"ok": false, "message": "incidentScheduler.rng.%s could not be structurally located in the save's raw JSON" % key}
		var span: Dictionary = rng_members[key]
		var token := text.substr(span["start"], span["end"] - span["start"])
		var parsed := _parse_json_integer_token(token)
		if not parsed["ok"]:
			return {"ok": false, "message": "incidentScheduler.rng.%s is not a supported 64-bit integer" % key}
		rng[key] = parsed["value"]
	return {"ok": true}

## Same for the optional top-level "digFindRng" (ADR 026, ItemTable.dig_find_random).
static func _restore_exact_dig_find_rng(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not (state.get("digFindRng") is Dictionary):
		return {"ok": true}
	var rng: Dictionary = state["digFindRng"]
	if not rng.has("seed") and not rng.has("state"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("digFindRng"):
		return {"ok": false, "message": "digFindRng could not be structurally located in the save's raw JSON"}
	var rng_span: Dictionary = (located_state["members"] as Dictionary)["digFindRng"]
	var text: String = located_state["text"]
	var rng_start: int = rng_span["start"]
	if rng_start >= text.length() or text[rng_start] != "{":
		return {"ok": false, "message": "digFindRng is not an object in the save's raw JSON"}
	var rng_members := _scan_object_members(text, rng_start + 1)
	if not rng_members.has("__end__"):
		return {"ok": false, "message": "digFindRng object could not be structurally parsed from the save's raw JSON"}
	for key in ["seed", "state"]:
		if not rng.has(key):
			continue
		if not rng_members.has(key):
			return {"ok": false, "message": "digFindRng.%s could not be structurally located in the save's raw JSON" % key}
		var span: Dictionary = rng_members[key]
		var token := text.substr(span["start"], span["end"] - span["start"])
		var parsed := _parse_json_integer_token(token)
		if not parsed["ok"]:
			return {"ok": false, "message": "digFindRng.%s is not a supported 64-bit integer" % key}
		rng[key] = parsed["value"]
	return {"ok": true}

## Same for the direct "seed" member of "state" (never "rng"'s nested seed or an envelope key).
static func _restore_exact_seed(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not state.has("seed"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("seed"):
		return {"ok": false, "message": "seed could not be structurally located in the save's raw JSON"}
	var span: Dictionary = (located_state["members"] as Dictionary)["seed"]
	var text: String = located_state["text"]
	var token := text.substr(span["start"], span["end"] - span["start"])
	var parsed := _parse_json_integer_token(token)
	if not parsed["ok"]:
		return {"ok": false, "message": "seed is not a supported 64-bit integer"}
	state["seed"] = parsed["value"]
	return {"ok": true}

## The direct members of the envelope's "state" object, each mapped to its raw value span, with
## key escapes decoded. {"ok": false} when malformed, so callers fail closed.
static func _locate_state_object(text: String) -> Dictionary:
	var pos := _skip_ws(text, 0)
	if pos >= text.length() or text[pos] != "{":
		return {"ok": false}
	var root_members := _scan_object_members(text, pos + 1)
	if not root_members.has("__end__") or not root_members.has("state"):
		return {"ok": false}
	var state_span: Dictionary = root_members["state"]
	var state_start: int = state_span["start"]
	if state_start >= text.length() or text[state_start] != "{":
		return {"ok": false}
	var state_members := _scan_object_members(text, state_start + 1)
	if not state_members.has("__end__"):
		return {"ok": false}
	return {"ok": true, "members": state_members, "text": text}

## The direct members of the object at `pos` (after its `{`): decoded key -> {start, end} raw
## value span; never recurses. A duplicate key keeps the last occurrence, like
## JSON.parse_string. "__end__" (not a valid key) is the position after `}`; absent = malformed.
static func _scan_object_members(text: String, pos: int) -> Dictionary:
	var members := {}
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return members
	if text[pos] == "}":
		members["__end__"] = pos + 1
		return members
	while true:
		pos = _skip_ws(text, pos)
		if pos >= text.length() or text[pos] != "\"":
			return {}
		var key_result := _parse_json_string(text, pos)
		if not key_result["ok"]:
			return {}
		var key: String = key_result["value"]
		pos = _skip_ws(text, key_result["end"])
		if pos >= text.length() or text[pos] != ":":
			return {}
		pos = _skip_ws(text, pos + 1)
		var value_start := pos
		var value_end := _skip_json_value(text, pos)
		if value_end < 0:
			return {}
		members[key] = {"start": value_start, "end": value_end}
		pos = _skip_ws(text, value_end)
		if pos >= text.length():
			return {}
		if text[pos] == ",":
			pos += 1
			continue
		if text[pos] == "}":
			members["__end__"] = pos + 1
			return members
		return {}
	return {} # unreachable; satisfies the static analyzer's return-path check

## Compiled once per class load: compiling per token made a large save read quadratic.
static var _number_regex: RegEx = null

static func _get_number_regex() -> RegEx:
	if _number_regex == null:
		_number_regex = RegEx.new()
		_number_regex.compile(_JSON_NUMBER_PATTERN)
	return _number_regex

## The position after the JSON value at `pos`, or -1 if malformed. Skipped values are never
## decoded, which matters on a 256x256 map's tile and route arrays.
static func _skip_json_value(text: String, pos: int) -> int:
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return -1
	var c := text[pos]
	if c == "\"":
		return _skip_json_string(text, pos)
	if c == "{":
		return _skip_json_object(text, pos + 1)
	if c == "[":
		return _skip_json_array(text, pos + 1)
	if text.substr(pos, 4) == "true":
		return pos + 4
	if text.substr(pos, 5) == "false":
		return pos + 5
	if text.substr(pos, 4) == "null":
		return pos + 4
	var num_match := _get_number_regex().search(text, pos)
	if num_match == null or num_match.get_start() != pos:
		return -1
	return num_match.get_end()

## The position after the object at `pos` (after its `{`), or -1; never decodes keys.
static func _skip_json_object(text: String, pos: int) -> int:
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return -1
	if text[pos] == "}":
		return pos + 1
	while true:
		pos = _skip_ws(text, pos)
		if pos >= text.length() or text[pos] != "\"":
			return -1
		var key_end := _skip_json_string(text, pos)
		if key_end < 0:
			return -1
		pos = _skip_ws(text, key_end)
		if pos >= text.length() or text[pos] != ":":
			return -1
		pos = _skip_ws(text, pos + 1)
		var value_end := _skip_json_value(text, pos)
		if value_end < 0:
			return -1
		pos = _skip_ws(text, value_end)
		if pos >= text.length():
			return -1
		if text[pos] == ",":
			pos += 1
			continue
		if text[pos] == "}":
			return pos + 1
		return -1
	return -1 # unreachable; satisfies the static analyzer's return-path check

## The position after the string literal at `pos` (a `"`), or -1; never builds the value.
static func _skip_json_string(text: String, pos: int) -> int:
	if pos >= text.length() or text[pos] != "\"":
		return -1
	var i := pos + 1
	var length := text.length()
	while i < length:
		var c := text[i]
		if c == "\"":
			return i + 1
		if c == "\\":
			i += 2
			continue
		i += 1
	return -1

## The position after the array at `pos` (after its `[`), or -1 if malformed.
static func _skip_json_array(text: String, pos: int) -> int:
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return -1
	if text[pos] == "]":
		return pos + 1
	while true:
		var value_end := _skip_json_value(text, pos)
		if value_end < 0:
			return -1
		pos = _skip_ws(text, value_end)
		if pos >= text.length():
			return -1
		if text[pos] == ",":
			pos = _skip_ws(text, pos + 1)
			continue
		if text[pos] == "]":
			return pos + 1
		return -1
	return -1 # unreachable; satisfies the static analyzer's return-path check

## Decodes the string literal at `pos`, \uXXXX included, so an escaped key equals the plain
## one as in JSON.parse_string(). {"ok": false} when unterminated or malformed.
static func _parse_json_string(text: String, pos: int) -> Dictionary:
	if pos >= text.length() or text[pos] != "\"":
		return {"ok": false}
	var i := pos + 1
	var out := ""
	while i < text.length():
		var c := text[i]
		if c == "\"":
			return {"ok": true, "value": out, "end": i + 1}
		if c == "\\":
			i += 1
			if i >= text.length():
				return {"ok": false}
			var esc := text[i]
			match esc:
				"\"":
					out += "\""
				"\\":
					out += "\\"
				"/":
					out += "/"
				"b":
					out += char(0x08)
				"f":
					out += char(0x0C)
				"n":
					out += "\n"
				"r":
					out += "\r"
				"t":
					out += "\t"
				"u":
					if i + 4 >= text.length():
						return {"ok": false}
					var hex := text.substr(i + 1, 4)
					if not hex.is_valid_hex_number(false):
						return {"ok": false}
					out += char(hex.hex_to_int())
					i += 4
				_:
					return {"ok": false}
			i += 1
		else:
			out += c
			i += 1
	return {"ok": false}

static func _skip_ws(text: String, pos: int) -> int:
	while pos < text.length() and (text[pos] == " " or text[pos] == "\t" or text[pos] == "\n" or text[pos] == "\r"):
		pos += 1
	return pos

## The exact int64 of a whole-number token ("1000", "1e3" and "1000.0" all give 1000), or
## {"ok": false} for a real fraction or an out-of-range magnitude -- never a wrapped value.
static func _parse_json_integer_token(token: String) -> Dictionary:
	var pattern := RegEx.new()
	pattern.compile("^(-)?(0|[1-9][0-9]*)(?:\\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$")
	var m := pattern.search(token)
	if m == null:
		return {"ok": false}
	var negative := m.get_string(1) == "-"
	var int_part := m.get_string(2)
	var frac_digits := m.get_string(3)
	var exp_group := m.get_string(4)

	var digits := int_part + frac_digits
	var mantissa_is_zero := digits.lstrip("0") == ""

	# A zero mantissa is 0 for any exponent; decided before the padding guard below.
	if mantissa_is_zero:
		return {"ok": true, "value": 0}

	# A huge exponent (e.g. "1e9999...") is decided here, before to_int() could overflow.
	var exponent := 0
	if not exp_group.is_empty():
		var exp_negative := exp_group.begins_with("-")
		var exp_significant := exp_group.lstrip("+-").lstrip("0")
		if exp_significant.length() > 6:
			return {"ok": false}
		exponent = exp_significant.to_int()
		if exp_negative:
			exponent = -exponent

	var point := int_part.length() + exponent
	if point < 0:
		if not mantissa_is_zero:
			return {"ok": false}
		digits = "0"
	elif point < digits.length():
		var fraction := digits.substr(point)
		if fraction.lstrip("0") != "":
			return {"ok": false}
		digits = digits.substr(0, point)
	else:
		var pad := point - digits.length()
		# Longer than int64's digit count is out of range; reject before padding.
		if pad > _INT64_MAX_DIGITS.length():
			return {"ok": false}
		digits += "0".repeat(pad)

	digits = digits.lstrip("0")
	if digits == "":
		digits = "0"

	if negative:
		if digits.length() > _INT64_MIN_MAGNITUDE_DIGITS.length() or (digits.length() == _INT64_MIN_MAGNITUDE_DIGITS.length() and digits > _INT64_MIN_MAGNITUDE_DIGITS):
			return {"ok": false}
		if digits == _INT64_MIN_MAGNITUDE_DIGITS:
			return {"ok": true, "value": -9223372036854775807 - 1}
		return {"ok": true, "value": -digits.to_int()}
	if digits.length() > _INT64_MAX_DIGITS.length() or (digits.length() == _INT64_MAX_DIGITS.length() and digits > _INT64_MAX_DIGITS):
		return {"ok": false}
	return {"ok": true, "value": digits.to_int()}

static func _coerce_floats_to_ints(value) -> void:
	if value is Dictionary:
		for key in value.keys():
			var entry: Variant = value[key]
			if typeof(entry) == TYPE_FLOAT and float(entry) == int(entry):
				value[key] = int(entry)
			elif entry is Dictionary or entry is Array:
				_coerce_floats_to_ints(entry)
	elif value is Array:
		for i in range(value.size()):
			var entry: Variant = value[i]
			if typeof(entry) == TYPE_FLOAT and float(entry) == int(entry):
				value[i] = int(entry)
			elif entry is Dictionary or entry is Array:
				_coerce_floats_to_ints(entry)
