class_name SaveJsonInts
extends RefCounted

## Exact 64-bit integers for SaveIO.read(): JSON.parse_string() returns every number as a
## float, so the seed and RNG fields are re-read from their raw tokens in the wire text.

## Full JSON number grammar (RFC 8259), used to capture the complete numeric
## token for the seed/rng fields rather than a bare `-?\d+` prefix -- a
## prefix match on "1e3" or "1.5" would stop at the leading digit and silently
## misread the value.
const _JSON_NUMBER_PATTERN := "-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"

const _INT64_MAX_DIGITS := "9223372036854775807"

const _INT64_MIN_MAGNITUDE_DIGITS := "9223372036854775808"

## JSON.parse_string always converts numbers to float, which cannot hold a
## 64-bit RandomNumberGenerator seed/state exactly. Recover the precise value
## by locating the structural position of "rng"."seed"/"state" inside the
## already-located "state" object (`located_state`, built once by
## _locate_state_object()) and reading the complete raw JSON number token at
## that exact span -- not by text-searching the whole file, which cannot
## distinguish an object boundary from a same-named key elsewhere in the
## envelope, and cannot decode a key written with a JSON \uXXXX escape.
## Returns {"ok": false} -- never a silent fall back to the
## lossy float-derived value already sitting in `state` -- when a token is
## fractional, exceeds the signed 64-bit range, or cannot be structurally
## located at all despite the parsed Variant claiming the field exists.
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

## Mirrors _restore_exact_rng() for "incidentScheduler"."rng"."seed"/"state":
## IncidentScheduler's own independent RandomNumberGenerator snapshot
## is exactly as vulnerable to JSON's lossy float round trip as world's own
## "rng" is -- its .state is an engine-internal 64-bit counter that can
## easily exceed 2^53 regardless of how small the seed is. One extra
## structural descent (state -> incidentScheduler -> rng) versus
## _restore_exact_rng()'s state -> rng, since this field nests one level
## deeper than the top-level "rng" object.
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

## Mirrors _restore_exact_rng() for the top-level "digFindRng"."seed"/"state"
## (ADR 026): world._dig_find_random's own continuation is
## exactly as vulnerable to JSON's lossy float round trip as "rng" is. Same
## nesting depth as _restore_exact_rng() (state -> digFindRng), just a
## different top-level key; optional throughout since this field itself is
## optional on the wire (SaveIO.OPTIONAL_TOP_LEVEL_FIELDS).
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

## Mirrors _restore_exact_rng() for the top-level "seed" field: a seed near or beyond 2^53 loses precision through the ordinary
## float round trip JSON.parse_string() performs, same as rng.seed/state did.
## Reads the *direct* "seed" member of the "state" object located by
## _locate_state_object() -- `_scan_object_members()` only ever descends one
## level per call, so this can never be confused by "rng"'s own nested
## "seed" key (which lives one level deeper, inside "rng"'s own member scan,
## never surfacing in `state`'s direct member list) or by a same-named field
## on the envelope itself (outside "state" entirely, never scanned here).
## Returns {"ok": false} -- never a silent fall back to the lossy
## float-derived value -- for a fractional or out-of-64-bit-range token, or
## when the field cannot be structurally located at all.
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

## Structurally locates the envelope's top-level "state" object and returns
## the *direct* (one level deep) members of that object -- each mapped to the
## raw text span of its still-unparsed value -- so callers can read the exact
## on-disk spelling of a specific field's number token without ever treating
## a substring match anywhere else in the file as if it were that field.
## Decodes JSON string escapes (including \uXXXX) while scanning key names,
## so an escaped key spells the same field a plain one would. Returns {"ok": false} if the envelope or "state" is malformed --
## this should never happen for text that already parsed successfully via
## JSON.parse_string, but a caller must fail closed rather than silently
## falling back to a lossy value if it somehow does.
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

## Parses a JSON object's *direct* members, starting at `pos` (the position
## right after the object's opening `{`). Returns a Dictionary from each
## decoded key to {"start": int, "end": int}: the raw text span of that
## member's still-unparsed value (a number's span is exactly its complete
## token text; an object/array/string's span covers its own delimiters).
## Never recurses into a nested object/array's own members -- a caller that
## needs those calls this again with that value's own span. A duplicate key
## keeps the last occurrence, matching JSON.parse_string's own dictionary
## build (repeated key overwrites). The returned Dictionary's "__end__" entry
## (never a valid JSON key, so it cannot collide with a real member) holds
## the position right after the object's closing `}`; its absence means the
## text was not a well-formed object starting at `pos`.
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

## Lazily-compiled, cached once per class load: a save's "state" object can
## carry tens of thousands of number tokens (e.g. a 256x256 map's own
## coordinate/id fields), and RegEx.compile() is not cheap -- compiling it
## fresh on every single token turned every save read into an O(field count)
## series of regex compiles, not just an O(text length) scan.
static var _number_regex: RegEx = null

static func _get_number_regex() -> RegEx:
	if _number_regex == null:
		_number_regex = RegEx.new()
		_number_regex.compile(_JSON_NUMBER_PATTERN)
	return _number_regex

## Returns the position right after the complete JSON value starting at
## `pos` (string, number, object, array, true, false, or null), or -1 if
## `pos` does not begin a well-formed value. Used only to skip past a
## member's value while scanning for sibling keys -- the caller that actually
## wants "state"'s or "rng"'s own direct members calls _scan_object_members()
## directly with that object's own span, never through here. Skips string and
## nested-object content without decoding or mapping it (`_skip_json_string()`/
## `_skip_json_object()`) -- a value being skipped is never inspected, so
## building its decoded text or member map, only to immediately discard it,
## would be pure waste over a large save (a 256x256 map's 65536-entry
## `tiles` array, its route-search `visited`/`frontier` tile lists, etc.).
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

## Returns the position right after the JSON object starting at `pos` (the
## position right after the object's opening `{`), or -1 if malformed --
## mirrors _scan_object_members() but never decodes a key or builds a member
## map, since a sibling value being skipped is never inspected (only used by
## _skip_json_value() for a nested object it is skipping over, never for
## "state" or "rng" themselves).
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

## Returns the position right after the JSON string literal starting at
## `pos` (which must be `"`), or -1 if unterminated -- unlike
## _parse_json_string(), never builds the decoded value, since a value being
## skipped (as opposed to a key being matched against "seed"/"rng"/"state")
## is never inspected.
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

## Returns the position right after the JSON array starting at `pos` (the
## position right after the array's opening `[`), or -1 if malformed.
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

## Decodes one JSON string literal starting at `pos` (which must be `"`),
## resolving backslash escapes -- including `\uXXXX` -- so an escaped key
## (e.g. "seed") decodes to the identical string a plain one would
## ("seed"), matching what JSON.parse_string() itself already does when it
## builds the parsed Dictionary's keys. Returns
## {"ok": false} for an unterminated or malformed literal.
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

## Decomposes one complete JSON number token (as matched by _JSON_NUMBER_PATTERN)
## into its exact integer value when the token denotes a mathematically whole
## number that fits in a signed 64-bit integer -- JSON gives "1000", "1e3" and
## "1000.0" the identical meaning regardless of surface form, so all three
## restore to the same exact int. Returns {"ok": false} for a token with a
## genuine (non-zero) fractional remainder, or one whose magnitude exceeds
## int64, rather than truncating or overflowing it into a plausible-looking
## wrong value.
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

	# Zero times any power of ten is exactly zero, independent of the
	# exponent's magnitude or sign -- "0", "-0", "0.0e21" and "0e999999999999"
	# all denote the same integer 0. Deciding this before any exponent
	# magnitude/padding logic keeps a zero mantissa from ever being rejected
	# by the padding-length guard below.
	if mantissa_is_zero:
		return {"ok": true, "value": 0}

	# A short token can spell an arbitrarily long exponent (e.g.
	# "1e999999999999999999999999"). Converting that many digits with
	# to_int() can itself overflow/wrap before the value is ever used, and no
	# legitimate in-range int64 needs an exponent whose significant digit
	# count exceeds a handful of digits -- so a longer one is decided here,
	# without ever computing its exact numeric value.
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
		# Any padded length beyond int64's own maximum digit count is
		# unconditionally out of range; reject before ever allocating the
		# padded string, so a short token can never request unbounded work
		# here either.
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
