extends ConfirmationDialog

## The New Game confirmation: resolves the toolbar's seed field, lets the player pick a
## scenarios.json entry (A16, ADR 053; "new_game" preselected) and asks before boot.gd
## regenerates the live world with pending_seed and pending_scenario_id.

const ScenarioBuilderType = preload("res://scripts/core/world/scenario_builder.gd")

const TextTableType = preload("res://scripts/viewer/text_table.gd")

var pending_seed: int = 0
var pending_scenario_id: String = ScenarioBuilderType.NEW_GAME_SCENARIO_ID
var scenario_picker := OptionButton.new()
var _text_table: TextTableType

func _init(text_table: TextTableType = null) -> void:
	_text_table = text_table if text_table != null else TextTableType.new()
	title = _text_table.get_string("new_game.title")
	add_child(scenario_picker)
	scenario_picker.item_selected.connect(_on_scenario_selected)

## One picker item per scenario entry (the registry's id-sorted list), labelled by its
## "label" text key through TextTable; the item metadata is the scenario id.
func set_scenarios(scenarios: Array) -> void:
	scenario_picker.clear()
	for scenario: Dictionary in scenarios:
		scenario_picker.add_item(_text_table.get_string(String(scenario["label"])))
		var index := scenario_picker.item_count - 1
		scenario_picker.set_item_metadata(index, String(scenario["id"]))
		if scenario["id"] == pending_scenario_id:
			scenario_picker.select(index)

func _on_scenario_selected(index: int) -> void:
	pending_scenario_id = String(scenario_picker.get_item_metadata(index))

## Resolves the seed field (blank picks one via the application layer's own
## global RNG -- never core, see simulation-boundaries.md) and writes the
## resolved value back so it stays visible/documented, then asks for
## confirmation before regenerating the live world. Returns "" when the
## dialog opened, else the status text explaining why not.
func ask(seed_input: LineEdit) -> String:
	var seed_text := seed_input.text.strip_edges()
	var seed_value: int
	if seed_text.is_empty():
		seed_value = randi()
	elif seed_text.is_valid_int():
		seed_value = seed_text.to_int()
	else:
		return _text_table.get_string("new_game.seed_invalid")
	seed_input.text = str(seed_value)
	pending_seed = seed_value
	dialog_text = _text_table.format("new_game.confirm_text", [seed_value])
	popup_centered()
	return ""
