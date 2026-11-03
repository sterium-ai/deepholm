class_name TreeGrowth
extends RefCounted

## F6a (ADR 067): sapling growth, composed by FarmSystem. A forest's stages are tile kinds
## (forests.json "stages", planted to oldest) and its grown_tile is the tree, so the viewer,
## passability and chop read the stage from the tile; this module keeps how far each sapling
## has grown and flips the tile at each stage threshold, then to the grown tile.
## Invariants:
## - saplings["x,y,z"] = {"forest", "growth"} exists exactly for the tiles whose kind is a stage
##   of that forest (FarmSystem reconciles every dirty cell, and the whole map after decode()).
## - growth goes up by one per tick (no season) until grow_days * day_length_ticks (ripe);
##   stage i shows from growth >= ripe * i / n (n stages). At ripe the tile becomes grown_tile
##   and the record goes, unless a colonist stands on it: the grown tile is impassable, so the
##   flip waits until the tile is free.
## - Iteration is in sorted key order; no RNG is drawn.
## - Hashed and persisted by FarmSystem as "saplings". Derived: the rule tables.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")

## One forests.json entry.
class ForestRule:
	var stages: Array[String] = []
	var ripe: int = 0
	var grown_tile: String = ""
	var plant_job: String = ""

var saplings: Dictionary = {}
## forests.json ids in content order.
var forest_ids: Array[String] = []

var _tile_grid: TileGridType
var _is_cell_occupied: Callable
## forests.json id -> ForestRule.
var _rules: Dictionary = {}
## stage tile id -> [forest id, stage index].
var _stage_of_tile: Dictionary = {}

## is_cell_occupied is WorldState's (tile, excluding_colonist_id) query; an empty Callable
## treats every tile as free.
func _init(content: ContentRegistryType, day_length_ticks: int, tile_grid: TileGridType, is_cell_occupied: Callable) -> void:
	_tile_grid = tile_grid
	_is_cell_occupied = is_cell_occupied
	for forest: Dictionary in content.list("forests"):
		var rule := ForestRule.new()
		var stages: Array = forest["stages"]
		rule.stages.assign(stages)
		var grow_days: int = forest["grow_days"]
		rule.ripe = grow_days * day_length_ticks
		rule.grown_tile = forest["grown_tile"]
		rule.plant_job = forest["plant_job"]
		var forest_id: String = forest["id"]
		forest_ids.append(forest_id)
		_rules[forest_id] = rule
		for i in rule.stages.size():
			_stage_of_tile[rule.stages[i]] = [forest_id, i]

## The jobs.json kind that plants forest_id; "" for an unknown forest.
func plant_job_of(forest_id: String) -> String:
	if not _rules.has(forest_id):
		return ""
	var rule: ForestRule = _rules[forest_id]
	return rule.plant_job

## Every forest's plant job kind, in content order (FarmSystem's claimed job kinds).
func plant_jobs() -> Array[String]:
	var kinds: Array[String] = []
	for forest_id in forest_ids:
		var kind := plant_job_of(forest_id)
		if kind not in kinds:
			kinds.append(kind)
	return kinds

## True when kind is some forest's stage tile (FarmSystem's whole-map reconcile).
func is_stage_tile(kind: String) -> bool:
	return _stage_of_tile.has(kind)

## One cell: a stage tile gets a record (growth at its stage's threshold) unless it already
## has one of the same forest; any other tile loses its record.
func reconcile(cell: Vector3i) -> void:
	var key := TileGridType.comma_key(cell)
	var kind := _tile_grid.tile_at(cell)
	if not _stage_of_tile.has(kind):
		saplings.erase(key)
		return
	var stage: Array = _stage_of_tile[kind]
	var forest_id: String = stage[0]
	if saplings.has(key) and (saplings[key] as Dictionary)["forest"] == forest_id:
		return
	var rule: ForestRule = _rules[forest_id]
	var stage_index: int = stage[1]
	saplings[key] = {"forest": forest_id, "growth": ceili(float(rule.ripe * stage_index) / float(rule.stages.size()))}

## The record keys, sorted.
func keys() -> Array:
	var sorted := saplings.keys()
	sorted.sort()
	return sorted

## One tick of growth for every sapling, in key order.
func grow() -> void:
	for key: String in keys():
		var record: Dictionary = saplings[key]
		var rule: ForestRule = _rules[record["forest"]]
		var cell := TileGridType.coord_of_comma_key(key)
		var previous: int = record["growth"]
		var growth := mini(previous + 1, rule.ripe)
		record["growth"] = growth
		if growth < rule.ripe:
			_set_tile(cell, _stage_tile(rule, growth))
		elif not (_is_cell_occupied.is_valid() and _is_cell_occupied.call(cell, "")):
			saplings.erase(key)
			_set_tile(cell, rule.grown_tile)

## The stage tile shown at growth: the last stage whose threshold growth has reached.
func _stage_tile(rule: ForestRule, growth: int) -> String:
	var shown := 0
	for i in rule.stages.size():
		if growth * rule.stages.size() >= rule.ripe * i:
			shown = i
	return rule.stages[shown]

## Writes a stage change through the dirty log (the grown tile changes passability).
func _set_tile(cell: Vector3i, kind: String) -> void:
	var index := _tile_grid.index_of(cell)
	if _tile_grid.tiles[index] == kind:
		return
	_tile_grid.tiles[index] = kind
	_tile_grid.mark_dirty(cell)

## {} when tile holds no sapling; else {"forest", "growth", "ripe_growth"} (viewer/tests).
func sapling_at(tile: Vector3i) -> Dictionary:
	var key := TileGridType.comma_key(tile)
	if not saplings.has(key):
		return {}
	var record: Dictionary = (saplings[key] as Dictionary).duplicate()
	var rule: ForestRule = _rules[record["forest"]]
	record["ripe_growth"] = rule.ripe
	return record

## The "saplings" save list: [{target, forest, growth}] in key order.
func encode() -> Array:
	var list: Array = []
	for key: String in keys():
		var cell := TileGridType.coord_of_comma_key(key)
		var record: Dictionary = saplings[key]
		list.append({"target": {"x": cell.x, "y": cell.y, "z": cell.z}, "forest": record["forest"], "growth": record["growth"]})
	return list

## Restores the records; FarmSystem.decode() reconciles them with the tiles afterwards.
func decode(list: Array) -> void:
	saplings = {}
	for entry: Dictionary in list:
		var target: Dictionary = entry["target"]
		var forest_id: String = entry["forest"]
		var growth: int = entry["growth"]
		saplings[TileGridType.comma_key(TileGrid.tile_of(target))] = {"forest": forest_id, "growth": growth}
