extends SceneTree

## Source-scanning lint (issue #282, ADR 012 "an accessor layer, not a new
## colonist shape"): proves that core simulation code reads a colonist/
## actor's needs, labourTable, route or held_tool fields only through
## ActorTable.has_component()/get_component(), never by indexing the raw
## dict directly, and never compares a bare "colonist" string literal outside
## the actor spawn path. Modeled on test_architecture_rules.gd's own
## _check_viewer_purity(): a plain text scan (regex-based), not a parser.
##
## "work" and "carrying" are deliberately NOT in PROTECTED_FIELDS: ADR 012's
## component vocabulary is mover/worker/needs/health/inventory/combat/wild/
## visitor only -- work/carrying are ToilExecutor-owned per-job execution
## state with no component of their own (the ADR is explicit that real
## movement/work stays owned by ToilExecutor/GlobalAssignment against the
## actual route/work shape, not a second accessor). Routing them through
## get_component() would require adding a component actor_table.gd does not
## declare, which is out of this task's Owned paths.
##
## EXCLUDED_DIRS/EXCLUDED_FILES cover directories/modules this task does not
## own and that legitimately need the raw shape: persistence/*.gd is the
## save/load wire-format boundary (task t4's own domain, explicitly out of
## this task's Non-goals); tool_item_store.gd/tool_fetch_toil.gd/
## tool_drop_toil.gd/calendar_alert_giver.gd are pre-existing companion
## modules toil_executor.gd/WorldState delegate to that this task's Owned
## paths do not list.
##
## Detection is provenance-based, not name-based (round 2 review: a blanket
## "any receiver ending in _component is exempt" rule let a raw actor alias
## renamed to foo_component evade the lint entirely, and the old "anchor"
## allowlist only recognized colonist/actor and a few fixed aliases, so
## _colonists[0]["needs"] and worker["needs"] passed through undetected).
## Per function (reset at every "func " line):
##  - a receiver is flagged when it is a literal "colonist"/"actor", an
##    underscore-delimited alias of one (target_colonist, other_actor,
##    _colonists, all_actors, ...), a direct index off such a collection
##    (_colonists[0]["needs"]), or any plain local alias assigned from one
##    of those (var worker = colonist; worker["needs"] -- tracked, not
##    name-matched). Alias tracking recognizes "=" and inferred-type ":="
##    assignment, a trailing "# comment" after the assignment, and a
##    "for worker in _colonists:" loop header (the loop variable is tainted
##    from the iterable's provenance the same as a plain alias);
##  - a receiver is exempt ONLY when it was itself assigned from
##    ActorTable.get_component(...) earlier in the same function -- tracked
##    by the actual assignment, never by the variable's name. A raw actor
##    alias that happens to be named ..._component (var foo_component =
##    actor) is NOT exempt: it was never actually routed through the
##    accessor, so the lint still flags it. Reassigning a name that
##    currently holds a verified component result -- worker =
##    ActorTableType.get_component(...) followed later by worker = colonist
##    -- revokes the exemption: every assignment (component call, alias, or
##    loop header) first clears whatever provenance the target previously
##    had, then re-derives it from the new right-hand side alone, so a name
##    is never both "exempt" and "tainted" from different points in time.
##  - each statement's reads are checked against provenance as it stood
##    BEFORE that statement, and provenance updates for later statements only
##    afterward (round 5 finding): a statement that both reassigns a tainted
##    name AND reads a protected field on its own right-hand side --
##    worker = ActorTableType.get_component(worker["needs"], "worker",
##    _content), worker = lookup[worker.get("needs")], or
##    for worker in lookup[worker.get("needs")]: -- must still flag that
##    read even though the same statement exempts or untaints "worker" for
##    every statement after it.
## This is still a text scan, not a type checker: a receiver with no
## traceable link back to a colonist/actor name (request, saved,
## _pending[worker] -- GlobalAssignment's own routing-request bookkeeping,
## which legitimately has its own unrelated "route" field) is left alone,
## same as before.

const CORE_DIR := "res://scripts/core"
const PROTECTED_FIELDS: Array[String] = ["needs", "labourTable", "route", "held_tool"]

const EXCLUDED_FILES: Array[String] = [
	"res://scripts/core/actors/actor_table.gd",
	"res://scripts/core/jobs/tool_item_store.gd",
	"res://scripts/core/jobs/tool_fetch_toil.gd",
	"res://scripts/core/jobs/tool_drop_toil.gd",
	"res://scripts/core/jobs/givers/calendar_alert_giver.gd",
]
const EXCLUDED_DIRS: Array[String] = [
	"res://scripts/core/actors/components",
	"res://scripts/core/persistence",
]

## file -> Array[String] of function names exempt from the "colonist" string-
## literal check: _spawn_colonists() is the actor spawn path itself. There is
## no equivalent field-access exemption table: every scanned function must
## route needs/labourTable/route/held_tool reads through the accessor,
## including WorldState's own repair helpers (_ensure_needs/_ensure_held_tool
## do so -- see their doc comments).
const COLONIST_LITERAL_EXEMPT_FUNCS := {
	"res://scripts/core/world_state.gd": ["_spawn_colonists"],
}

## A receiver's base identifier counts as a colonist/actor anchor when one of
## its underscore-delimited parts IS "colonist"/"colonists"/"actor"/"actors"
## (so both singular receivers like "colonist" and plural collections like
## "_colonists"/"all_actors" match, but an unrelated word that merely
## contains "actor" as a substring -- route_search_factory, refactor -- does
## not, since neither splits into a part that equals "actor"/"actors").
func _is_anchor_identifier(name: String) -> bool:
	for part in name.split("_"):
		if part == "colonist" or part == "colonists" or part == "actor" or part == "actors":
			return true
	return false

## The identifier text immediately in front of a "[" or ".", e.g. "_colonists"
## out of a captured receiver "_colonists[0]".
func _base_identifier(receiver_text: String) -> String:
	var bracket := receiver_text.find("[")
	if bracket < 0:
		return receiver_text
	return receiver_text.substr(0, bracket)

var _index_regexes: Dictionary = {}
var _get_regexes: Dictionary = {}
var _component_assign_regex: RegEx
var _alias_assign_regex: RegEx
var _for_in_regex: RegEx
var _colonist_literal_regex: RegEx

var _failed := false
var _scanned := 0

func _init() -> void:
	_compile_patterns()
	_run_self_tests()
	if _failed:
		quit(1)
		return
	_scan_dir(CORE_DIR)
	_expect(_scanned > 0, "lint must actually scan at least one script")
	if _failed:
		quit(1)
		return
	print("test_actor_field_lint: PASS (%d files scanned)" % _scanned)
	quit(0)

func _compile_patterns() -> void:
	# A receiver is a bare identifier, or an identifier chained through one or
	# more "[...]" index reads (so "_colonists[0]" is captured whole, letting
	# the direct-chain case _colonists[0]["needs"] resolve its base identifier
	# to "_colonists" instead of evading detection because nothing but "]"
	# sits directly in front of the protected-field bracket).
	var receiver := "(\\w+(?:\\s*\\[[^\\[\\]]*\\])*)"
	for field in PROTECTED_FIELDS:
		var index_regex := RegEx.new()
		index_regex.compile(receiver + "\\s*\\[\\s*['\"]%s['\"]\\s*\\]" % field)
		_index_regexes[field] = index_regex
		var get_regex := RegEx.new()
		get_regex.compile(receiver + "\\s*\\.\\s*get\\s*\\(\\s*['\"]%s['\"]" % field)
		_get_regexes[field] = get_regex
	_colonist_literal_regex = RegEx.new()
	_colonist_literal_regex.compile("['\"]colonist['\"]\\s*(==|!=)|(==|!=)\\s*['\"]colonist['\"]")
	# var? NAME[: TYPE] = <anything>ActorTable...get_component( -- provenance
	# for the ONLY legitimate exemption: NAME actually came out of the
	# accessor, regardless of what NAME is called. The assignment operator is
	# either inferred-type ":=" or a plain "=" (optionally preceded by an
	# explicit ": TYPE" annotation) -- both spellings Godot accepts.
	_component_assign_regex = RegEx.new()
	_component_assign_regex.compile(
		"^(?:var\\s+)?(\\w+)\\s*(?::=|(?::\\s*[\\w.\\[\\],]+)?\\s*=)\\s*\\w*ActorTable\\w*\\.get_component\\s*\\(")
	# var? NAME[: TYPE] = SOURCE or var? NAME := SOURCE, where SOURCE is a
	# bare identifier or an identifier chained through index reads and
	# nothing else (no calls, no operators) -- a plain alias, e.g.
	# "var worker = colonist", "var worker := colonist" or
	# "var foo_component = actor". Deliberately conservative: an RHS with a
	# method call or expression is left untracked rather than guessed at.
	_alias_assign_regex = RegEx.new()
	_alias_assign_regex.compile(
		"^(?:var\\s+)?(\\w+)\\s*(?::=|(?::\\s*[\\w.\\[\\],]+)?\\s*=)\\s*(\\w+(?:\\s*\\[[^\\[\\]]*\\])*)\\s*$")
	# for NAME in SOURCE[:] -- a loop header. The loop variable's provenance
	# is derived from the iterable exactly like a plain alias assignment
	# (for worker in _colonists: taints "worker" for the rest of the
	# function, same conservative no-scoping approximation the alias tracker
	# already uses).
	_for_in_regex = RegEx.new()
	_for_in_regex.compile("^for\\s+(\\w+)\\s+in\\s+(\\w+(?:\\s*\\[[^\\[\\]]*\\])*)")

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Self-test coverage for the scanner itself, run against small in-memory
## snippets before any real file is scanned: proves the quote/whitespace/
## alias/multi-occurrence gaps prior review rounds found are actually closed,
## that provenance (not the receiver's name) decides the component-wrapper
## exemption, and that legitimate accessor usage and unrelated dictionaries
## (GlobalAssignment's own routing-request bookkeeping) are never flagged.
func _run_self_tests() -> void:
	_expect(_violations_for_lines(['colonist["needs"]']).size() == 1,
		"double-quoted index read must be flagged")
	_expect(_violations_for_lines(["colonist['needs']"]).size() == 1,
		"single-quoted index read must be flagged")
	_expect(_violations_for_lines(['colonist[ "needs" ]']).size() == 1,
		"whitespace inside an index read must not evade detection")
	_expect(_violations_for_lines(['colonist.get("needs")']).size() == 1,
		"double-quoted get() read must be flagged")
	_expect(_violations_for_lines(["colonist.get('needs')"]).size() == 1,
		"single-quoted get() read must be flagged")
	_expect(_violations_for_lines(['colonist.get( "needs" )']).size() == 1,
		"whitespace inside a get() read must not evade detection")
	_expect(_violations_for_lines(['target_colonist["route"]']).size() == 1,
		"an aliased colonist receiver (target_colonist) must be flagged")
	_expect(_violations_for_lines(['other_actor.get("held_tool")']).size() == 1,
		"an aliased actor receiver (other_actor) must be flagged")
	_expect(_violations_for_lines(['colonist["route"] = colonist["route"]']).size() == 1,
		"the LHS assignment target is allowed but the RHS read must still be flagged")
	_expect(_violations_for_lines(['colonist["labourTable"] = {}']).size() == 0,
		"a whole-field assignment target must not be flagged (ActorTable has no setter)")

	# Collection-index receiver (round 2 finding): a direct chain off a
	# colonist collection, with no intermediate variable to name-match on.
	_expect(_violations_for_lines(['_colonists[0]["needs"]']).size() == 1,
		"indexing straight into a colonist collection must be flagged even with no named receiver")
	_expect(_violations_for_lines(['all_actors[i].get("route")']).size() == 1,
		"indexing straight into an actor collection must be flagged even with no named receiver")
	# A collection-index receiver unrelated to colonists/actors (GlobalAssignment's
	# own request bookkeeping) must stay clean -- "route" collides in name only.
	_expect(_violations_for_lines(['_pending[worker]["route"]']).size() == 0,
		"a non-actor routing-request dictionary must not be flagged just because its receiver is indexed")

	# Ordinary alias (round 2 finding): a plain local variable that holds a
	# colonist/actor, under a name the lint cannot recognize on its own.
	_expect(_violations_for_lines(["func f():", "\tvar worker = colonist", '\tworker["needs"]']).size() == 1,
		"an alias assigned from colonist must be flagged under its own name, not just as colonist itself")
	_expect(_violations_for_lines(["func f():", "\tvar helper = actor", '\thelper.get("held_tool")']).size() == 1,
		"an alias assigned from actor must be flagged under its own name")
	# An unrelated variable name never linked to colonist/actor stays clean:
	# the lint tracks provenance, it does not flag every dictionary read.
	_expect(_violations_for_lines(["func f():", "\tvar request = {}", '\trequest["route"]']).size() == 0,
		"a dictionary never assigned from colonist/actor must not be flagged")

	# Raw actor renamed to look like a component wrapper (round 2 finding):
	# proves the _component-suffix exemption is gone -- only an actual
	# get_component() call earns the exemption now.
	_expect(_violations_for_lines(["func f():", "\tvar foo_component = actor", '\tfoo_component["needs"]']).size() == 1,
		"a raw actor alias named *_component with no get_component() call must still be flagged")

	# Legitimate accessor result: only a genuine get_component() call earns
	# the exemption, and it holds even when the variable's own name would
	# otherwise be flagged as a colonist/actor alias (colonist_component).
	_expect(_violations_for_lines([
			"func f():",
			'\tvar worker_component = ActorTableType.get_component(colonist, "worker", _content)',
			'\tworker_component["labourTable"]']).size() == 0,
		"a genuine get_component() result must not be flagged")
	_expect(_violations_for_lines([
			"func f():",
			'\tvar colonist_component = ActorTableType.get_component(actor, "worker", _content)',
			'\tcolonist_component["labourTable"]']).size() == 0,
		"get_component() provenance must exempt the result even if its name also looks like a colonist alias")
	_expect(_violations_for_lines(['needs_component.has("food")']).size() == 0,
		"a read of an unrelated field/method on a component-shaped name must not be flagged")
	_expect(_violations_for_lines([
			'var route = ActorTableType.get_component(colonist, "mover", _content)']).size() == 0,
		"the accessor call itself must not be flagged")

	# Inferred-type alias (round 3 finding): "var worker := colonist" must
	# taint "worker" exactly like "var worker = colonist" does.
	_expect(_violations_for_lines(["func f():", "\tvar worker := colonist", '\tworker["needs"]']).size() == 1,
		"an inferred-type alias (:=) assigned from colonist must be flagged under its own name")
	_expect(_violations_for_lines([
			"func f():",
			'\tvar worker := ActorTableType.get_component(colonist, "worker", _content)',
			'\tworker["labourTable"]']).size() == 0,
		"an inferred-type (:=) get_component() result must not be flagged")

	# Trailing comment on the assignment line (round 3 finding): "$" in the
	# alias regex must not be defeated by a "# comment" after the alias.
	_expect(_violations_for_lines(["func f():", "\tvar worker = colonist  # alias", '\tworker["needs"]']).size() == 1,
		"an alias assignment followed by a trailing comment must still be tracked")

	# Iteration alias (round 3 finding): "for worker in _colonists:" taints
	# the loop variable from the iterable's provenance, same as a plain
	# alias assignment.
	_expect(_violations_for_lines(["func f():", "\tfor worker in _colonists:", '\t\tworker["needs"]']).size() == 1,
		"a for-loop variable iterating a colonist collection must be flagged under its own name")
	_expect(_violations_for_lines(["func f():", "\tfor actor in all_actors:", '\t\tactor.get("route")']).size() == 1,
		"a for-loop variable iterating an actor collection must be flagged under its own name")
	_expect(_violations_for_lines(["func f():", "\tfor item in queue:", '\t\titem["route"]']).size() == 0,
		"a for-loop over an unrelated collection must not be flagged")

	# Reassignment revokes a component exemption (round 3 finding): a name
	# that once held a verified get_component() result must lose its
	# exemption the moment it is reassigned to a raw colonist/actor.
	_expect(_violations_for_lines([
			"func f():",
			'\tvar worker = ActorTableType.get_component(colonist, "worker", _content)',
			"\tworker = colonist",
			'\tworker["needs"]']).size() == 1,
		"reassigning a verified component result to a raw actor must revoke the exemption")
	# ... and the converse: reassigning a tainted alias to a genuine
	# get_component() result must grant the exemption from that point on.
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			'\tworker = ActorTableType.get_component(colonist, "worker", _content)',
			'\tworker["labourTable"]']).size() == 0,
		"reassigning a tainted alias to a genuine get_component() result must grant the exemption")

	# Self-referential reassignment/iteration must not lose provenance (round 4
	# finding): resetting the target's provenance before reading the source's
	# taint let a same-name assignment or loop header silently erase a live
	# alias's taint one line before its protected-field read.
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			'\tworker = worker["needs"]']).size() == 1,
		"reassigning a tainted alias from its own indexed read must still flag the RHS read")
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			"\tworker = worker",
			'\tworker["needs"]']).size() == 1,
		"a plain self-assignment (worker = worker) must not erase a previously tracked taint")
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			"\tfor worker in worker:",
			'\t\tworker["needs"]']).size() == 1,
		"a for-loop variable that shadows its own iterable's name must not erase a previously tracked taint")

	# Same-statement reassignment whose RHS itself reads a protected field
	# through the pre-assignment alias (round 5 finding): checking this
	# statement's reads against provenance from BEFORE the statement, before
	# updating provenance for statements after it, must still flag these.
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			'\tworker = ActorTableType.get_component(worker["needs"], "worker", _content)']).size() == 1,
		"a get_component() call whose own argument reads a protected field via the pre-assignment alias must still be flagged")
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			'\tworker = lookup[worker.get("needs")]']).size() == 1,
		"reassigning an alias through an untainted lookup must still flag a protected-field read on the RHS")
	_expect(_violations_for_lines([
			"func f():",
			"\tvar worker = colonist",
			'\tfor worker in lookup[worker.get("needs")]:']).size() == 1,
		"a for-loop header whose iterable expression itself reads a protected field via the pre-loop alias must still be flagged")

	_expect(_colonist_literal_violation('if kind == "colonist":'),
		"a double-quoted colonist comparison must be flagged")
	_expect(_colonist_literal_violation("if kind == 'colonist':"),
		"a single-quoted colonist comparison must be flagged")
	_expect(_colonist_literal_violation('if kind=="colonist":'),
		"a colonist comparison without surrounding spaces must be flagged")
	_expect(not _colonist_literal_violation('if kind == "colonist_template":'),
		"a longer literal must not false-positive on the colonist check")

func _is_excluded_dir(path: String) -> bool:
	for dir in EXCLUDED_DIRS:
		if path == dir or path.begins_with(dir + "/"):
			return true
	return false

func _scan_dir(path: String) -> void:
	if _is_excluded_dir(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		_fail("could not open %s" % path)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full_path := path + "/" + name
		if dir.current_is_dir():
			_scan_dir(full_path)
		elif name.ends_with(".gd"):
			_scan_file(full_path)
		name = dir.get_next()
	dir.list_dir_end()

func _scan_file(path: String) -> void:
	if EXCLUDED_FILES.has(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("could not open %s" % path)
		return
	var text := file.get_as_text()
	file.close()
	_scanned += 1
	var literal_exempt: Array = COLONIST_LITERAL_EXEMPT_FUNCS.get(path, [])
	var current_func := ""
	var tainted: Dictionary = {}
	var components: Dictionary = {}
	for raw_line in text.split("\n"):
		var line := String(raw_line)
		var stripped := line.strip_edges()
		if stripped.begins_with("func "):
			current_func = _func_name(stripped)
			tainted = {}
			components = {}
		if stripped.begins_with("#"):
			continue
		for violation in _line_violations(line, tainted, components):
			_fail("%s: reads %s directly -- use ActorTable.get_component() instead: %s"
				% [path, violation, line.strip_edges()])
		_update_provenance(stripped, tainted, components)
		if not literal_exempt.has(current_func) and _colonist_literal_violation(line):
			_fail("%s: compares a bare \"colonist\" string literal outside the actor spawn path: %s"
				% [path, line.strip_edges()])

func _func_name(stripped_line: String) -> String:
	var after_func := stripped_line.substr(5)
	var paren := after_func.find("(")
	if paren < 0:
		return after_func.strip_edges()
	return after_func.substr(0, paren).strip_edges()

## Every PROTECTED_FIELDS violation on lines, scanned with the same per-
## function provenance rules _scan_file() uses on real files -- a small
## in-memory equivalent so self-tests can exercise alias/get_component()
## tracking across a few lines, not just a single isolated line.
func _violations_for_lines(lines: Array) -> Array:
	var tainted: Dictionary = {}
	var components: Dictionary = {}
	var violations: Array = []
	for raw_line in lines:
		var line := String(raw_line)
		var stripped := line.strip_edges()
		if stripped.begins_with("func "):
			tainted = {}
			components = {}
		if stripped.begins_with("#"):
			continue
		violations.append_array(_line_violations(line, tainted, components))
		_update_provenance(stripped, tainted, components)
	return violations

## True when text right before "#" is outside any '...'/"..." string -- used
## to strip a trailing "# comment" before provenance regexes see the line,
## since their "$" anchor would otherwise never match a commented alias line
## (var worker = colonist  # alias).
func _strip_comment(line: String) -> String:
	var in_single := false
	var in_double := false
	for i in line.length():
		var ch := line[i]
		if ch == "'" and not in_double:
			in_single = not in_single
		elif ch == "\"" and not in_single:
			in_double = not in_double
		elif ch == "#" and not in_single and not in_double:
			return line.substr(0, i)
	return line

## Clears any provenance target previously held (exempt component-wrapper OR
## tainted alias) so a fresh assignment always fully replaces the old
## classification instead of merely adding to it. Without this, a name that
## once held a verified get_component() result stayed exempt forever, even
## after being reassigned to a raw colonist/actor (round 3 finding).
func _reset_provenance(target: String, tainted: Dictionary, components: Dictionary) -> void:
	tainted.erase(target)
	components.erase(target)

## Updates tainted/components in place from a single (already-stripped) line:
## a genuine ActorTable...get_component() assignment marks its target as a
## verified component-wrapper (the only path to exemption); a plain alias
## assignment or "for x in ..." loop header from an already-known colonist/
## actor propagates that taint to its target under the target's own name,
## however unrelated that name looks. Every assignment first resets the
## target's prior provenance (see _reset_provenance) so reassigning an
## exempt name to a raw actor revokes the exemption rather than keeping it.
##
## Source provenance is read BEFORE the target's reset, never after (round 4
## finding): when the target and source share a name -- "worker = worker",
## "worker = worker[\"needs\"]", "for worker in worker:" -- resetting the
## target first would erase the very taint the source lookup needs to see,
## silently untainting a name that is still a live colonist/actor alias one
## line later. Every branch below computes its "is the source tainted"
## boolean from the dictionaries as they stood at the start of the line, only
## THEN calls _reset_provenance() and (conditionally) re-applies the derived
## classification, so a self-referential assignment or loop header carries
## its provenance forward unchanged instead of losing it.
func _update_provenance(stripped_line: String, tainted: Dictionary, components: Dictionary) -> void:
	var line := _strip_comment(stripped_line).strip_edges()
	var component_match := _component_assign_regex.search(line)
	if component_match != null:
		var target: String = component_match.get_string(1)
		_reset_provenance(target, tainted, components)
		components[target] = true
		return
	var for_match := _for_in_regex.search(line)
	if for_match != null:
		var loop_target: String = for_match.get_string(1)
		var loop_source: String = _base_identifier(for_match.get_string(2))
		var loop_source_tainted: bool = _is_anchor_identifier(loop_source) or tainted.has(loop_source)
		_reset_provenance(loop_target, tainted, components)
		if loop_source_tainted:
			tainted[loop_target] = true
		return
	var alias_match := _alias_assign_regex.search(line)
	if alias_match == null:
		return
	var target: String = alias_match.get_string(1)
	var source: String = _base_identifier(alias_match.get_string(2))
	var source_tainted: bool = _is_anchor_identifier(source) or tainted.has(source)
	_reset_provenance(target, tainted, components)
	if source_tainted:
		tainted[target] = true

## True when base_identifier should be treated as holding a colonist/actor
## dictionary directly: recognized by name, or by a traced alias assignment
## earlier in the same function. components (real get_component() results)
## are deliberately NOT eligible here -- checked separately as an exemption
## before this is even consulted.
func _is_flaggable_receiver(base_identifier: String, tainted: Dictionary) -> bool:
	return _is_anchor_identifier(base_identifier) or tainted.has(base_identifier)

## Every PROTECTED_FIELDS violation on line, as "identifier[\"field\"]" or
## "identifier.get(\"field\")" strings: every regex match is examined (not
## just the first), so e.g. colonist["route"] = colonist["route"] still
## catches the RHS read even though the LHS is an allowed assignment target.
func _line_violations(line: String, tainted: Dictionary, components: Dictionary) -> Array:
	var violations: Array = []
	for field in PROTECTED_FIELDS:
		for m in _index_regexes[field].search_all(line):
			var receiver: String = m.get_string(1)
			var base := _base_identifier(receiver)
			if components.has(base):
				continue
			if not _is_flaggable_receiver(base, tainted):
				continue
			if _is_assignment_target(line, m.get_end()):
				continue
			violations.append("%s[\"%s\"]" % [receiver, field])
		for m in _get_regexes[field].search_all(line):
			var receiver: String = m.get_string(1)
			var base := _base_identifier(receiver)
			if components.has(base):
				continue
			if not _is_flaggable_receiver(base, tainted):
				continue
			violations.append("%s.get(\"%s\")" % [receiver, field])
	return violations

## True when the text right after a ["field"] index is a plain "=" (not
## "=="), meaning the index is an assignment target, not a read.
func _is_assignment_target(line: String, after: int) -> bool:
	var rest := line.substr(after).strip_edges()
	if not rest.begins_with("="):
		return false
	return rest.length() < 2 or rest[1] != "="

func _colonist_literal_violation(line: String) -> bool:
	return _colonist_literal_regex.search(line) != null
