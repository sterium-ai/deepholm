extends ConfirmationDialog

## The New Game confirmation: resolves the toolbar's seed field and asks
## before boot.gd regenerates the live world with pending_seed.

const TextTableType = preload("res://scripts/viewer/text_table.gd")

var pending_seed: int = 0
var _text_table: TextTableType

func _init(text_table: TextTableType = null) -> void:
	_text_table = text_table if text_table != null else TextTableType.new()
	title = _text_table.get_string("new_game.title")

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
