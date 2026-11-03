extends VBoxContainer

## Minimal stockpile panel (F5a, ADR 064), on the workbench panel's pattern: one block per
## stockpile zone (world.get_zones() without farm zones) with its priority (- / + buttons) and
## one toggle button per item group. Every button issues a zone_set_stockpile command through
## world.apply(), the only mutation here (test_architecture_rules.gd's viewer-purity check).
##
## Refresh follows the work table's A9 pattern: rows are rebuilt only when the set of
## stockpiles changes; an ordinary tick-driven refresh() rewrites the already-alive labels and
## button texts in place, so a button the player is pressing is never freed under them.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const ZoneTableType = preload("res://scripts/core/objects/zone_table.gd")

var world: WorldStateType
var _text_table: TextTableType
## Ids of the stockpiles the rows were built for, in get_zones() order.
var _zone_ids: Array[String] = []
## zone id -> its priority Label; "zone_id:group" -> that group's toggle Button.
var _priority_labels: Dictionary = {}
var _group_buttons: Dictionary = {}
var _command_sequence: int = 0

func setup(world_ref: WorldStateType, text_table: TextTableType) -> void:
	world = world_ref
	_text_table = text_table
	refresh()

func refresh() -> void:
	if world == null:
		return
	var stockpiles := _stockpiles()
	var ids: Array[String] = []
	for zone in stockpiles:
		ids.append(String(zone["id"]))
	if ids != _zone_ids:
		_rebuild(stockpiles)
		_zone_ids = ids
	for zone in stockpiles:
		_update(zone)

func _stockpiles() -> Array[Dictionary]:
	return world.get_zones().filter(func(zone: Dictionary) -> bool: return not zone.has("kind"))

## The groups a filter can name, as ZoneTable lists them (the items' kinds).
func _groups() -> Array[String]:
	return ZoneTableType.groups_of(world.get_content_list("items"))

func _rebuild(stockpiles: Array[Dictionary]) -> void:
	for child in get_children():
		child.queue_free()
	_priority_labels.clear()
	_group_buttons.clear()
	if stockpiles.is_empty():
		var none := Label.new()
		none.text = _text_table.get_string("stockpile.none")
		add_child(none)
		return
	for zone in stockpiles:
		var zone_id := String(zone["id"])
		var title := Label.new()
		title.text = _text_table.get_string("stockpile.title") % [int(zone["x"]), int(zone["y"])]
		add_child(title)
		var priority_row := HBoxContainer.new()
		add_child(priority_row)
		var priority_label := Label.new()
		priority_label.custom_minimum_size.x = 140
		priority_row.add_child(priority_label)
		_priority_labels[zone_id] = priority_label
		priority_row.add_child(_button(_text_table.get_string("stockpile.less"), _on_priority_step.bind(zone_id, -1)))
		priority_row.add_child(_button(_text_table.get_string("stockpile.more"), _on_priority_step.bind(zone_id, 1)))
		var group_row := HFlowContainer.new()
		add_child(group_row)
		for group in _groups():
			var button := _button("", _on_group_toggle.bind(zone_id, group))
			group_row.add_child(button)
			_group_buttons["%s:%s" % [zone_id, group]] = button

func _button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(48, 40)
	button.pressed.connect(on_pressed)
	return button

func _update(zone: Dictionary) -> void:
	var zone_id := String(zone["id"])
	var label: Label = _priority_labels.get(zone_id)
	if label != null:
		label.text = _text_table.get_string("stockpile.priority") % ZoneTableType.priority_of(zone)
	var accepted := _accepted(zone)
	for group in _groups():
		var button: Button = _group_buttons.get("%s:%s" % [zone_id, group])
		if button == null:
			continue
		var state_key := "stockpile.accepts" if accepted.has(group) else "stockpile.rejects"
		button.text = _text_table.get_string(state_key) % _text_table.get_string("stockpile.group.%s" % group)

## The groups zone accepts: its "groups", or every group when it has none (the default).
func _accepted(zone: Dictionary) -> Array[String]:
	var accepted: Array[String] = []
	accepted.assign(zone.get("groups", _groups()))
	return accepted

func _live(zone_id: String) -> Dictionary:
	return world.get_zone(zone_id)

func _send(zone_id: String, groups: Array[String], priority: int) -> Dictionary:
	_command_sequence += 1
	var result := world.apply({"actor": "player", "command_id": "stockpile_%d" % _command_sequence,
		"tick": world.get_tick(), "type": "zone_set_stockpile",
		"payload": {"id": zone_id, "groups": ",".join(groups), "priority": priority}})
	refresh()
	return result

func _on_priority_step(zone_id: String, step: int) -> void:
	var zone := _live(zone_id)
	if zone.is_empty():
		return
	var priority := clampi(ZoneTableType.priority_of(zone) + step, ZoneTableType.MIN_PRIORITY, ZoneTableType.MAX_PRIORITY)
	_send(zone_id, _accepted(zone), priority)

func _on_group_toggle(zone_id: String, group: String) -> void:
	var zone := _live(zone_id)
	if zone.is_empty():
		return
	var groups := _accepted(zone)
	if groups.has(group):
		groups.erase(group)
	else:
		groups.append(group)
	_send(zone_id, groups, ZoneTableType.priority_of(zone))
