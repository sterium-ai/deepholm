extends SceneTree

## F5b review evidence: writes the committed v11 save whose colonists carry no "skills" (the
## field is optional in a save and seeded on load). It takes F6a's v11 fixture, unpacks it,
## drops every colonist's "skills", keeps schemaVersion 11 and writes it through SaveIO's own
## commit_body(), whose read-back migrates it to v12 and validates it before the rename.
## write_atomic() is not used: it accepts only the current schema. Run from the repo root:
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
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SOURCE))["state"]
	SaveIOType._coerce_ints(state)
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
