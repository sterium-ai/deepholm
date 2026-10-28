extends SceneTree

## A15 text lint (ADR 052): no player-facing English literal is left in the
## viewer (game/scripts/viewer/*.gd and boot.gd). Every visible string is a
## data/text key resolved through TextTable, so a translation never has to
## touch code. A string literal counts as player text when, once its format
## specifiers and escapes are removed, it holds two words separated by a space
## or starts with a capitalised word ("Recruit", "Build rejected: %s").
## Identifiers, text keys, node names, ids built with "%s_%d" and compass
## codes ("NE", "edge:N") do not. Exempt, because no player sees them:
## print()/push_error()/push_warning()/printerr()/assert() lines, comments,
## and a line carrying a "# dev-text" marker (developer diagnostics such as
## command_recorder.gd's replay-file errors). The lint first proves it still
## catches a planted literal, so it cannot pass by matching nothing.

const VIEWER_DIR := "res://scripts/viewer"
const BOOT_PATH := "res://scripts/boot.gd"
const DEV_TEXT_MARKER := "# dev-text"
const DIAGNOSTIC_CALLS := ["print(", "push_error(", "push_warning(", "printerr(", "assert("]

var _failed := false
var _format_spec := RegEx.create_from_string("%[-+0-9.]*[sdifxXcv%]|\\{[a-z_]+\\}|\\\\[ntr\"\\\\]")
var _two_words := RegEx.create_from_string("[A-Za-z]{2,}\\s+[A-Za-z]")
var _capitalised_word := RegEx.create_from_string("^\\s*[A-Z][a-z]")

func _init() -> void:
	_check_lint_catches_planted_literals()
	_check_viewer_has_no_player_literals()
	if _failed:
		quit(1)
		return
	print("test_viewer_text_lint: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The lint must flag literals of both shapes and skip every exempt one.
func _check_lint_catches_planted_literals() -> void:
	var planted := "\n".join([
		'\tlabel.text = "Hello there"',
		'\tbutton.text = "Recruit"',
		'\tstatus = "Build rejected: %s" % reason',
		'\tvar key := "status.idle"',
		'\tvar id := "viewer_build_%s_%d" % [kind, tick]',
		'\tvar corner := "NE"',
		'\tpush_error("Something went wrong: %s" % path)',
		'\t# label.text = "Commented out"',
		'\treturn {"message": "no replay file at %s" % path}  # dev-text',
		'\tvar field := "factionId"',
	])
	var findings := _lint_source("planted.gd", planted)
	_expect(findings.size() == 3, "the lint must flag exactly the three planted player literals, got %s" % [findings])
	for expected in ["Hello there", "Recruit", "Build rejected: %s"]:
		var found := false
		for finding in findings:
			found = found or finding.ends_with('"%s"' % expected)
		_expect(found, "the lint must flag the planted literal '%s', got %s" % [expected, findings])

func _check_viewer_has_no_player_literals() -> void:
	var paths: Array[String] = [BOOT_PATH]
	var dir := DirAccess.open(VIEWER_DIR)
	_expect(dir != null, "cannot open %s" % VIEWER_DIR)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".gd"):
			paths.append(VIEWER_DIR.path_join(file_name))
	_expect(paths.size() > 10, "the lint must scan the viewer scripts, found %d" % paths.size())
	var findings: Array[String] = []
	for path in paths:
		findings.append_array(_lint_source(path, FileAccess.get_file_as_string(path)))
	_expect(findings.is_empty(), "player-facing literals left in the viewer (move them to data/text/en.json):\n%s" % "\n".join(findings))

func _lint_source(path: String, source: String) -> Array[String]:
	var findings: Array[String] = []
	var lines := source.split("\n")
	for i in lines.size():
		var line := lines[i]
		if DEV_TEXT_MARKER in line:
			continue
		var literals: Array[String] = []
		var code := _code_and_literals(line, literals)
		var diagnostic := false
		for call in DIAGNOSTIC_CALLS:
			diagnostic = diagnostic or call in code
		if diagnostic:
			continue
		for literal in literals:
			if _is_player_text(literal):
				findings.append('%s:%d: "%s"' % [path, i + 1, literal])
	return findings

## The line's code with comments dropped, appending each string literal
## ("..." or '...') to `literals`. StringName (&"x") and NodePath (^"x") literals are
## names, never text, and are skipped.
func _code_and_literals(line: String, literals: Array[String]) -> String:
	var code := ""
	var i := 0
	while i < line.length():
		var ch := line[i]
		if ch == "#":
			break
		if ch != "\"" and ch != "'":
			code += ch
			i += 1
			continue
		var is_name := i > 0 and (line[i - 1] == "&" or line[i - 1] == "^")
		var literal := ""
		i += 1
		while i < line.length() and line[i] != ch:
			if line[i] == "\\" and i + 1 < line.length():
				literal += line[i] + line[i + 1]
				i += 2
				continue
			literal += line[i]
			i += 1
		i += 1
		code += "\"\""
		if not is_name:
			literals.append(literal)
	return code

func _is_player_text(literal: String) -> bool:
	if literal.begins_with("res://") or literal.begins_with("user://"):
		return false
	var bare := _format_spec.sub(literal, " ", true)
	return _two_words.search(bare) != null or _capitalised_word.search(bare) != null
