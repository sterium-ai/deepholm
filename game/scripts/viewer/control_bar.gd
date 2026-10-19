extends HFlowContainer

## The debug viewer's wrapping toolbar: tick/save controls, the New Game seed
## field, the active-seed label, order tool buttons, wall kinds, Rotate and
## one debug Spawn button per incident. Builds the buttons and wires them to
## the handlers boot.gd passes in; owns no game logic. Tool and wall-kind
## buttons are registered on the OrderInput so its selection updates them.

const OrderInputType = preload("res://scripts/viewer/order_input.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const StatusTextType = preload("res://scripts/viewer/status_text.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")

const TOOL_KEYS := ["dig", "chop", "forage", "cancel", "wall", "remove_object", "zone", "till", "sow", "mine"]

var seed_input: LineEdit
var active_seed_label: Label

## `on` maps each control to its handler: pause, step, speed (takes a
## TickDriver.Speed), save, load, center, select_tool (takes a tool, -1 to
## navigate), toggle_art, new_game, debug_scenario, select_wall_kind (takes a
## kind), rotate_build.
func build(text_table: TextTableType, orders: OrderInputType, incident_buttons: Array[Button], on: Dictionary) -> void:
	for entry in [
		["controls.pause", on["pause"]], ["controls.step", on["step"]],
		["controls.speed_x1", on["speed"].bind(TickDriverType.Speed.X1)],
		["controls.speed_x2", on["speed"].bind(TickDriverType.Speed.X2)],
		["controls.speed_x3", on["speed"].bind(TickDriverType.Speed.X3)], ["controls.save", on["save"]],
		["controls.load", on["load"]], ["controls.center", on["center"]],
		["controls.navigate", on["select_tool"].bind(-1)], ["controls.toggle_art", on["toggle_art"]]]:
		add_child(make_button(text_table.get_string(entry[0]), entry[1]))
	# New game controls: a visible, editable numeric seed --
	# left blank, boot.gd's _on_new_game_pressed() picks one and writes it back
	# here so it stays documented/visible, never silently chosen (see
	# docs/decisions/019-world-dimensions-and-generation.md). Hard-coded
	# English labels; not yet routed through the text table.
	seed_input = LineEdit.new()
	seed_input.placeholder_text = "Seed (blank = random)"
	seed_input.custom_minimum_size.x = 160
	add_child(seed_input)
	add_child(make_button("New Game", on["new_game"]))
	# Explicit opt-in to the seeded diagnostic scenario, which is kept as an
	# option and for fixtures but is never the default -- the random dig-order queue
	# and forced furniture DebugScenario.build() places are reachable from
	# the running viewer only by pressing this button, never at startup.
	add_child(make_button("Debug Scenario", on["debug_scenario"]))
	# The active world's own seed, distinct from
	# seed_input above: that field is an editable draft for the next New
	# Game, overwritten by _on_new_game_pressed() and never touched by Load,
	# so it goes stale/misleading the moment a different colony is restored.
	# This label always reflects whichever WorldState is actually running --
	# set by boot.gd for the world built at startup, and refreshed by
	# _replace_world() every time Load or New Game swaps it.
	active_seed_label = Label.new()
	add_child(active_seed_label)
	for tool in TOOL_KEYS.size():
		_add_tool_button(orders, tool, text_table.get_string("controls.tool_" + TOOL_KEYS[tool]), on["select_tool"])
	var wall_kinds := ButtonGroup.new()
	for kind in ["wooden_wall", "stone_wall"]:
		var button := make_button(text_table.get_string("controls." + kind), on["select_wall_kind"].bind(kind))
		button.toggle_mode = true
		button.button_group = wall_kinds
		button.set_pressed_no_signal(kind == orders.wall_kind)
		orders.wall_kind_buttons[kind] = button
		add_child(button)
	for entry in [["Build Door", OrderInputType.Tool.BUILD_DOOR], ["Build Bed", OrderInputType.Tool.BUILD_BED],
			["Build Workbench", OrderInputType.Tool.BUILD_WORKBENCH]]:
		_add_tool_button(orders, int(entry[1]), String(entry[0]), on["select_tool"])
	orders.rotate_build_button = make_button("Rotate (R)", on["rotate_build"])
	orders.rotate_build_button.toggle_mode = true
	orders.rotate_build_button.disabled = true
	add_child(orders.rotate_build_button)
	for incident_button in incident_buttons:
		add_child(incident_button)

func _add_tool_button(orders: OrderInputType, tool: int, text: String, select_tool: Callable) -> void:
	var button := make_button(text, select_tool.bind(tool))
	button.toggle_mode = true
	orders.tool_buttons[tool] = button
	add_child(button)

static func make_button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	return button

## One debug button per content/incidents.json row, each calling
## spawn_incident(id), so an incident can be triggered from the running
## viewer. Built into the bar by build(), and by test_incidents.gd through
## boot.gd's _make_incident_buttons() (a headless test never runs _ready()).
static func make_incident_buttons(world: WorldStateType, text_table: TextTableType, spawn_incident: Callable) -> Array[Button]:
	var buttons: Array[Button] = []
	for entry in world._content.list("incidents"):
		var incident_id := String(entry["id"])
		var button := Button.new()
		button.text = StatusTextType.incident_display_name(text_table, incident_id)
		button.tooltip_text = "Debug: trigger this incident now"
		button.set_meta("incident_id", incident_id)
		button.pressed.connect(spawn_incident.bind(incident_id))
		buttons.append(button)
	return buttons
