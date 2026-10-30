extends VBoxContainer

## Minimal workbench panel (F2, ADR 061): one block per colony workbench
## (world.get_crafting_benches()), one row per recipe the bench makes with its
## "keep N in stock" target (- / + buttons) and an "order 1 more" button, then
## the bench's order queue and the bill in progress, with a button that cancels
## the next order. Every button issues a craft_* command through world.apply(),
## the only mutation here (test_architecture_rules.gd's viewer-purity check).
##
## Refresh follows the work table's A9 pattern: rows are rebuilt only when the
## set of benches changes; an ordinary tick-driven refresh() rewrites the
## already-alive labels in place, so a button the player is pressing is never
## freed under them.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

var world: WorldStateType
var _text_table: TextTableType
## "x,y" of every bench the rows were built for, in get_crafting_benches() order.
var _bench_keys: Array[String] = []
## "x,y:recipe" -> the Label showing that target; "x,y" -> the bench's status Label.
var _target_labels: Dictionary = {}
var _status_labels: Dictionary = {}
var _command_sequence: int = 0

func setup(world_ref: WorldStateType, text_table: TextTableType) -> void:
	world = world_ref
	_text_table = text_table
	refresh()

func refresh() -> void:
	if world == null:
		return
	var benches := world.get_crafting_benches()
	var keys: Array[String] = []
	for bench in benches:
		keys.append(_key(bench))
	if keys != _bench_keys:
		_rebuild(benches)
		_bench_keys = keys
	for bench in benches:
		_update(bench)

func _key(bench: Dictionary) -> String:
	return "%d,%d" % [int(bench["x"]), int(bench["y"])]

func _rebuild(benches: Array[Dictionary]) -> void:
	for child in get_children():
		child.queue_free()
	_target_labels.clear()
	_status_labels.clear()
	if benches.is_empty():
		var none := Label.new()
		none.text = _text_table.get_string("workbench.none")
		add_child(none)
		return
	for bench in benches:
		var key := _key(bench)
		var title := Label.new()
		title.text = _text_table.get_string("workbench.title") % [int(bench["x"]), int(bench["y"])]
		add_child(title)
		for recipe in world.get_content_list("recipes"):
			if String(recipe["bench"]) != String(bench["kind"]):
				continue
			var recipe_id := String(recipe["id"])
			var row := HBoxContainer.new()
			add_child(row)
			var name_label := Label.new()
			name_label.text = _text_table.get_string("workbench.recipe.%s" % recipe_id)
			name_label.custom_minimum_size.x = 140
			row.add_child(name_label)
			var target_label := Label.new()
			target_label.custom_minimum_size.x = 90
			row.add_child(target_label)
			_target_labels["%s:%s" % [key, recipe_id]] = target_label
			row.add_child(_button("workbench.less", _on_target_step.bind(bench, recipe_id, -1)))
			row.add_child(_button("workbench.more", _on_target_step.bind(bench, recipe_id, 1)))
			row.add_child(_button("workbench.order_one", _on_order.bind(bench, recipe_id)))
		var status := Label.new()
		status.autowrap_mode = TextServer.AUTOWRAP_WORD
		add_child(status)
		_status_labels[key] = status
		add_child(_button("workbench.cancel_next", _on_cancel_next.bind(bench)))

func _button(text_key: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = _text_table.get_string(text_key)
	button.custom_minimum_size = Vector2(48, 40)
	button.pressed.connect(on_pressed)
	return button

func _update(bench: Dictionary) -> void:
	var key := _key(bench)
	var targets: Dictionary = bench["targets"]
	for label_key: String in _target_labels:
		if label_key.begins_with(key + ":"):
			var recipe_id := label_key.substr(key.length() + 1)
			(_target_labels[label_key] as Label).text = _text_table.get_string("workbench.keep") % int(targets.get(recipe_id, 0))
	var status: Label = _status_labels.get(key)
	if status == null:
		return
	var queue: Array[String] = []
	for order: Dictionary in (bench["orders"] as Array):
		queue.append(_text_table.get_string("workbench.order_entry") % [
			_text_table.get_string("workbench.recipe.%s" % String(order["recipe"])), int(order["remaining"])])
	var bill: Dictionary = bench["bill"]
	var now := _text_table.get_string("workbench.idle") if bill.is_empty() \
		else _text_table.get_string("workbench.recipe.%s" % String(bill["recipe"]))
	var queue_text := ", ".join(queue) if not queue.is_empty() else _text_table.get_string("workbench.queue_empty")
	status.text = _text_table.get_string("workbench.status") % [now, queue_text]

func _command(type: String, payload: Dictionary) -> Dictionary:
	_command_sequence += 1
	var result := world.apply({"actor": "player", "command_id": "workbench_%d" % _command_sequence,
		"tick": world.get_tick(), "type": type, "payload": payload})
	refresh()
	return result

func _on_target_step(bench: Dictionary, recipe_id: String, step: int) -> void:
	var current := 0
	for live in world.get_crafting_benches():
		if _key(live) == _key(bench):
			current = int((live["targets"] as Dictionary).get(recipe_id, 0))
	_command("craft_set_target", {"x": int(bench["x"]), "y": int(bench["y"]), "z": int(bench["z"]), "recipe": recipe_id, "count": maxi(0, current + step)})

func _on_order(bench: Dictionary, recipe_id: String) -> void:
	_command("craft_add_order", {"x": int(bench["x"]), "y": int(bench["y"]), "z": int(bench["z"]), "recipe": recipe_id, "count": 1})

func _on_cancel_next(bench: Dictionary) -> void:
	for live in world.get_crafting_benches():
		if _key(live) == _key(bench) and not (live["orders"] as Array).is_empty():
			_command("craft_cancel_order", {"x": int(bench["x"]), "y": int(bench["y"]), "z": int(bench["z"]), "order_id": String(live["orders"][0]["id"])})
			return
