extends RefCounted

## Content JSON reader for ContentRegistry (ADR 010). Static and dependency-free.

static func read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "message": "could not open %s" % path}
	var text := file.get_as_text()
	file.close()
	var parsed := parse_json(text)
	if not parsed["ok"]:
		return {"ok": false, "message": "%s: %s" % [path, parsed["message"]]}
	var value: Variant = parsed["value"]
	if typeof(value) != TYPE_DICTIONARY and typeof(value) != TYPE_ARRAY:
		return {"ok": false, "message": "%s did not parse as a JSON object or array" % path}
	return {"ok": true, "value": value}

## Recursive-descent parser that keeps JSON Schema's integer/number split, which
## JSON.parse_string() loses (every number becomes a float): a literal without '.' or
## exponent parses as int, anything else as float.
static func parse_json(text: String) -> Dictionary:
	var cursor := _JsonCursor.new(text)
	var value: Variant = _json_parse_value(cursor)
	if cursor.failed():
		return {"ok": false, "message": cursor.error_message}
	cursor.skip_whitespace()
	if not cursor.at_end():
		return {"ok": false, "message": "trailing content after JSON value (at offset %d)" % cursor.pos}
	return {"ok": true, "value": value}

class _JsonCursor extends RefCounted:
	var text: String
	var length: int
	var pos: int = 0
	var error_message: String = ""

	func _init(source: String) -> void:
		text = source
		length = source.length()

	func failed() -> bool:
		return not error_message.is_empty()

	func fail(message: String) -> void:
		if error_message.is_empty():
			error_message = "%s (at offset %d)" % [message, pos]

	func at_end() -> bool:
		return pos >= length

	func peek() -> String:
		if at_end():
			return ""
		return text[pos]

	func skip_whitespace() -> void:
		while not at_end():
			var c := text[pos]
			if c == " " or c == "\t" or c == "\n" or c == "\r":
				pos += 1
			else:
				break

static func _json_parse_value(c: _JsonCursor):
	c.skip_whitespace()
	if c.at_end():
		c.fail("unexpected end of input")
		return null
	var ch := c.peek()
	if ch == "{":
		return _json_parse_object(c)
	if ch == "[":
		return _json_parse_array(c)
	if ch == "\"":
		return _json_parse_string(c)
	if ch == "t" or ch == "f":
		return _json_parse_bool(c)
	if ch == "n":
		return _json_parse_null(c)
	if ch == "-" or (ch >= "0" and ch <= "9"):
		return _json_parse_number(c)
	c.fail("unexpected character '%s'" % ch)
	return null

static func _json_parse_object(c: _JsonCursor) -> Dictionary:
	var result := {}
	c.pos += 1 # consume '{'
	c.skip_whitespace()
	if c.peek() == "}":
		c.pos += 1
		return result
	while true:
		c.skip_whitespace()
		if c.peek() != "\"":
			c.fail("expected string key")
			return result
		var key := _json_parse_string(c)
		if c.failed():
			return result
		c.skip_whitespace()
		if c.peek() != ":":
			c.fail("expected ':' after object key")
			return result
		c.pos += 1
		var value: Variant = _json_parse_value(c)
		if c.failed():
			return result
		result[key] = value
		c.skip_whitespace()
		var next := c.peek()
		if next == ",":
			c.pos += 1
			continue
		if next == "}":
			c.pos += 1
			break
		c.fail("expected ',' or '}' in object")
		break
	return result

static func _json_parse_array(c: _JsonCursor) -> Array:
	var result := []
	c.pos += 1 # consume '['
	c.skip_whitespace()
	if c.peek() == "]":
		c.pos += 1
		return result
	while true:
		var value: Variant = _json_parse_value(c)
		if c.failed():
			return result
		result.append(value)
		c.skip_whitespace()
		var next := c.peek()
		if next == ",":
			c.pos += 1
			continue
		if next == "]":
			c.pos += 1
			break
		c.fail("expected ',' or ']' in array")
		break
	return result

static func _json_parse_string(c: _JsonCursor) -> String:
	c.pos += 1 # consume opening quote
	var out := ""
	while true:
		if c.at_end():
			c.fail("unterminated string")
			return out
		var ch := c.text[c.pos]
		if ch == "\"":
			c.pos += 1
			return out
		if ch == "\\":
			c.pos += 1
			if c.at_end():
				c.fail("unterminated escape sequence")
				return out
			var esc := c.text[c.pos]
			match esc:
				"\"": out += "\""
				"\\": out += "\\"
				"/": out += "/"
				"b": out += "\b"
				"f": out += "\f"
				"n": out += "\n"
				"r": out += "\r"
				"t": out += "\t"
				"u":
					if c.pos + 4 >= c.length:
						c.fail("truncated unicode escape")
						return out
					var hex := c.text.substr(c.pos + 1, 4)
					if not _is_hex4(hex):
						c.fail("invalid unicode escape '\\u%s'" % hex)
						return out
					out += char(hex.hex_to_int())
					c.pos += 4
				_:
					c.fail("invalid escape character '%s'" % esc)
					return out
			c.pos += 1
			continue
		# JSON forbids a raw (unescaped) control character inside a string
		# literal (RFC 8259 SS7); only an escape may produce one.
		if ch.unicode_at(0) < 0x20:
			c.fail("unescaped control character (code %d) in string" % ch.unicode_at(0))
			return out
		out += ch
		c.pos += 1
	return out

static func _is_hex4(s: String) -> bool:
	if s.length() != 4:
		return false
	for i in 4:
		if not _is_hex_digit(s[i]):
			return false
	return true

static func _is_hex_digit(ch: String) -> bool:
	return (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "f") or (ch >= "A" and ch <= "F")

static func _is_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"

## Strict RFC 8259 number grammar: "01", "1." and "1e" are rejected, never truncated (a
## truncated read would desync every later error offset).
static func _json_parse_number(c: _JsonCursor):
	var start := c.pos
	var is_float := false
	if c.peek() == "-":
		c.pos += 1
	if c.at_end() or not _is_digit(c.text[c.pos]):
		c.fail("invalid number literal")
		return 0
	if c.text[c.pos] == "0":
		c.pos += 1
	else:
		while not c.at_end() and _is_digit(c.text[c.pos]):
			c.pos += 1
	if not c.at_end() and c.text[c.pos] == ".":
		is_float = true
		c.pos += 1
		if c.at_end() or not _is_digit(c.text[c.pos]):
			c.fail("invalid number literal: expected a digit after '.'")
			return 0
		while not c.at_end() and _is_digit(c.text[c.pos]):
			c.pos += 1
	if not c.at_end() and (c.text[c.pos] == "e" or c.text[c.pos] == "E"):
		is_float = true
		c.pos += 1
		if not c.at_end() and (c.text[c.pos] == "+" or c.text[c.pos] == "-"):
			c.pos += 1
		if c.at_end() or not _is_digit(c.text[c.pos]):
			c.fail("invalid number literal: expected a digit after exponent marker")
			return 0
		while not c.at_end() and _is_digit(c.text[c.pos]):
			c.pos += 1
	var token := c.text.substr(start, c.pos - start)
	if is_float:
		return float(token)
	return int(token)

static func _json_parse_bool(c: _JsonCursor) -> bool:
	if c.text.substr(c.pos, 4) == "true":
		c.pos += 4
		return true
	if c.text.substr(c.pos, 5) == "false":
		c.pos += 5
		return false
	c.fail("invalid literal")
	return false

static func _json_parse_null(c: _JsonCursor):
	if c.text.substr(c.pos, 4) == "null":
		c.pos += 4
		return null
	c.fail("invalid literal")
	return null
