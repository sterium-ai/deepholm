class_name RecipeBook
extends RefCounted

## content/recipes.json (F2, ADR 061), read-only: recipes by id in id order, and the object
## kinds that are benches. ContentRegistry already checked every item id and bench kind, that
## no recipe lists an item twice on one side, and every quantity against MAX_COUNT.

## The one cap on a recipe quantity, a target or order count and a saved held quantity, so a
## recipe the registry accepts can always be saved (CraftingValidator, CraftingSystem).
const MAX_COUNT := 999
## The work job kinds a recipe may name in "job" (F5b, ADR 065); jobs.json gives each its
## labour. The first is the default.
const WORK_KINDS := ["craft_work", "cook_work"]

var _recipes: Dictionary = {}
var _ids: Array[String] = []
var _bench_kinds: Dictionary = {}

## recipe_list is ContentRegistry.list("recipes") (id-sorted, frozen; empty without the file).
func _init(recipe_list: Array) -> void:
	for recipe: Dictionary in recipe_list:
		var id: String = recipe["id"]
		var bench: String = recipe["bench"]
		_recipes[id] = recipe
		_ids.append(id)
		_bench_kinds[bench] = true

func ids() -> Array[String]:
	return _ids

func has(id: String) -> bool:
	return _recipes.has(id)

func is_bench_kind(kind: String) -> bool:
	return _bench_kinds.has(kind)

## "" for an unknown id.
func bench_of(id: String) -> String:
	var recipe: Dictionary = _recipes.get(id, {})
	return recipe.get("bench", "")

## The recipe's work job kind (WORK_KINDS); craft_work when it names none or is unknown.
func work_kind_of(id: String) -> String:
	var recipe: Dictionary = _recipes.get(id, {})
	return recipe.get("job", WORK_KINDS[0])

## [{item, quantity}]; [] for an unknown id.
func inputs(id: String) -> Array:
	var recipe: Dictionary = _recipes.get(id, {})
	return recipe.get("inputs", [])

func outputs(id: String) -> Array:
	var recipe: Dictionary = _recipes.get(id, {})
	return recipe.get("outputs", [])
