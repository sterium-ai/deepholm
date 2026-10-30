extends RefCounted

## A WorldState.get_view_snapshot()-shaped Dictionary (A9, view_snapshot.gd) built from
## plain actor dictionaries, for the FakeWorld stand-ins of tests that drive a viewer
## layer without a simulation. Only the columns are filled; the detail keys are empty.
## Use: const ViewSnapshotStub = preload("res://scripts/tests/support/view_snapshot_stub.gd")

## `actors` in table order; `worker_ids` {id: true} marks the colonists; `job_kinds`
## {job id: kind} resolves each actor's "work" job. An actor without a "health"
## Dictionary gets hp -1, like the real snapshot.
static func columns(actors: Array, worker_ids: Dictionary, job_kinds: Dictionary = {}) -> Dictionary:
	var ids := PackedStringArray()
	var kinds := PackedStringArray()
	var factions := PackedStringArray()
	var xs := PackedInt32Array()
	var ys := PackedInt32Array()
	var worker := PackedByteArray()
	var carrying := PackedStringArray()
	var tools := PackedStringArray()
	var trapped := PackedByteArray()
	var work_kinds := PackedStringArray()
	var hp := PackedInt32Array()
	var max_hp := PackedInt32Array()
	for actor: Dictionary in actors:
		ids.append(String(actor["id"]))
		kinds.append(String(actor.get("kind", "")))
		factions.append(String(actor.get("factionId", "colony")))
		xs.append(int(actor["x"]))
		ys.append(int(actor["y"]))
		worker.append(1 if worker_ids.has(String(actor["id"])) else 0)
		var cargo: Variant = actor.get("carrying")
		carrying.append(String((cargo as Dictionary)["kind"]) if cargo is Dictionary else "")
		tools.append("")
		trapped.append(0 if actor.get("trapped") == null else 1)
		var work: Variant = actor.get("work")
		work_kinds.append(String(job_kinds.get(String((work as Dictionary)["job_id"]), "")) if work is Dictionary else "")
		var health: Variant = actor.get("health")
		hp.append(int((health as Dictionary).get("hp", 0)) if health is Dictionary else -1)
		max_hp.append(int((health as Dictionary).get("maxHp", 1)) if health is Dictionary else -1)
	return {"tick": 0, "ids": Array(ids), "kinds": Array(kinds), "factions": Array(factions), "x": Array(xs),
		"y": Array(ys), "z": 0, "worker": Array(worker), "carrying": Array(carrying), "tool_kinds": Array(tools),
		"trapped": Array(trapped), "work_kinds": Array(work_kinds), "hp": Array(hp), "max_hp": Array(max_hp),
		"need_reasons": {}, "details": {}, "jobs": {}}
