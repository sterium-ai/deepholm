extends SceneTree

## F5b review evidence: writes the committed v11 save whose colonists carry no "skills" (the
## field is optional in a save and seeded on load). It takes F6a's v11 fixture, unpacks it,
## drops every colonist's "skills", keeps schemaVersion 11 and writes it through SaveIO's own
## commit_body(), whose read-back migrates it to v12 and validates it before the rename.
## write_atomic() is not used: it accepts only the current schema. The source is read the way
## SaveIO.read() reads it: JSON.parse_string() gives every number as a float, so the seed and
## the three RNG states are restored from their raw tokens (SaveJsonInts) before anything is
## written; otherwise the 64-bit RNG states would round. Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/F5b-write-noskills-save.gd -- <absolute-output-path>
## On the F5b branch it produced game/scripts/tests/fixtures/save_schema_v11_noskills_fixture.json.

const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SaveWireType = preload("res://scripts/core/persistence/save_wire.gd")

const SOURCE := "res://scripts/tests/fixtures/save_schema_v11_fixture.json"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <absolute-output-path>")
		quit(2)
		return
	var text := FileAccess.get_file_as_string(SOURCE)
	var state: Dictionary = JSON.parse_string(text)["state"]
	var located := SaveJsonInts._locate_state_object(text)
	SaveIOType._coerce_ints(state)
	for restored: Dictionary in [SaveJsonInts._restore_exact_rng(state, located),
			SaveJsonInts._restore_exact_seed(state, located),
			SaveJsonInts._restore_exact_incident_rng(state, located),
			SaveJsonInts._restore_exact_dig_find_rng(state, located)]:
		if not restored["ok"]:
			push_error("could not restore an exact integer from %s: %s" % [SOURCE, restored])
			quit(1)
			return
	var unpacked := SaveWireType.unpack(state, 4096)
	if not unpacked["ok"]:
		push_error("could not unpack %s: %s" % [SOURCE, unpacked])
		quit(1)
		return
	var stripped := 0
	for entity: Dictionary in state["entities"]:
		if entity["kind"] == "colonist" and entity.erase("skills"):
			stripped += 1
	var check := SaveIOType.content_check(SaveIOType._session(null))
	var result := SaveIOType.commit_body(args[0], SaveIOType.state_text(state), check)
	print("F5b-write-noskills-save: schemaVersion=%s stripped=%d result=%s" % [state["schemaVersion"], stripped, result])
	quit(0 if result.get("ok", false) and stripped > 0 else 1)
