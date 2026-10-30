class_name RecipeBook
extends RefCounted

## content/recipes.json (F2, ADR 061), read-only: recipes by id in id order, and the object
## kinds that are benches. ContentRegistry already checked every item id and bench kind.

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

## [{item, quantity}]; [] for an unknown id.
func inputs(id: String) -> Array:
	var recipe: Dictionary = _recipes.get(id, {})
	return recipe.get("inputs", [])

func outputs(id: String) -> Array:
	var recipe: Dictionary = _recipes.get(id, {})
	return recipe.get("outputs", [])
