extends ConfirmationDialog

## The New Game confirmation: resolves the toolbar's seed field and asks
## before boot.gd regenerates the live world with pending_seed.

var pending_seed: int = 0

func _init() -> void:
	title = "New Game"

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
		return "Seed must be a whole number, or blank for a random one."
	seed_input.text = str(seed_value)
	pending_seed = seed_value
	dialog_text = "Start a new game with seed %d? Your last save is kept until you press Save." % seed_value
	popup_centered()
	return ""
