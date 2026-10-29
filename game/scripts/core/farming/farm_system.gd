class_name FarmSystem
extends RefCounted

## F1 (ADR 059): crop growth on sown tiles and the farm-zone job-giver. A crop's stages are
## tile kinds (crops.json "stages", sown to ripe), so the viewer, passability and the
## harvest job's requires_tile read the stage from the tile; this module keeps how far each
## crop has grown and flips the tile at each stage threshold.
## Invariants:
## - crops["x,y"] = {"crop", "growth"} exists exactly for the tiles whose kind is a stage of
##   that crop: advance() reconciles every cell of the tile grid's dirty-cell stream (all
##   tiles when the stream was truncated, and after decode()), so a sow or a harvest is seen
##   in the tick it completes.
## - growth goes up by one per tick while the crop's calendar window is open, until
##   grow_days * day_length_ticks (ripe); stage i shows from growth >= ripe * i / (n - 1).
## - From the start of day window.to + wither_days_after_window + 1, an unripe crop's tile
##   turns into withered_tile and its record goes; a ripe crop waits for its harvest.
## - A crop's sow and harvest are its own jobs.json kinds (crops.json sow_job/harvest_job,
##   checked by CropContent): FarmGiver submits the zone crop's sow and the ripe crop's harvest,
##   so the crop chosen for a zone is what the work consumes, sets and yields.
## - Runs once per tick in TickPipeline's "farming" phase: reconcile, grow/wither, then
##   FarmGiver.advance(). Iteration is in sorted key order, so the same seed and commands
##   always change the same tiles in the same order.
## - Hashed and persisted: crops (hash_into() adds the key only when non-empty, so a world
##   without crops keeps its pre-F1 state_hash()). Derived: the dirty cursor, the rule tables.

const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const FarmGiverType = preload("res://scripts/core/jobs/givers/farm_giver.gd")

## One crops.json entry, resolved against the calendar once at construction.
class CropRule:
	var stages: Array[String] = []
	var ripe: int = 0
	var from_day: int = 0
	var to_day: int = 0
	var wither_day: int = 0
	var withered_tile: String = ""
	var seed_item: String = ""
	var sow_job: String = ""
	var harvest_job: String = ""

var crops: Dictionary = {}
var giver: FarmGiverType
## Every job kind FarmGiver submits or counts as a claim: till, then each crop's sow and harvest.
var job_kinds: Array[String] = [FarmGiverType.TILL_JOB]

var _calendar: CalendarServiceType
var _clock: SeededClock
var _tile_grid: TileGridType
## crops.json id -> CropRule.
var _rules: Dictionary = {}
## stage tile id -> [crop id, stage index].
var _stage_of_tile: Dictionary = {}
## sow job kind -> the seed item it consumes (FarmGiver's seed accounting).
var _sow_seeds: Dictionary = {}
var _dirty_cursor: int = 0

## get_farm_zones/get_items/submit/passability feed FarmGiver (see its _init); view_jobs_of_kinds
## is JobQueue.view_jobs_of_kinds, bound here to job_kinds.
func _init(content: ContentRegistryType, calendar: CalendarServiceType, clock: SeededClock, tile_grid: TileGridType,
		get_farm_zones: Callable, get_items: Callable, view_jobs_of_kinds: Callable, submit: Callable, passability: Callable) -> void:
	_calendar = calendar
	_clock = clock
	_tile_grid = tile_grid
	var windows: Dictionary = {}
	for window: Dictionary in calendar.window_definitions():
		var window_id: String = window["id"]
		windows[window_id] = window
	for crop: Dictionary in content.list("crops"):
		# A scenario calendar (ADR 057) may lack the crop's window: then the crop has no season
		# (never grows, never sown by a zone, and an unripe one withers at once).
		var window: Dictionary = windows.get(crop["window"], {"from": 1, "to": 0})
		var rule := CropRule.new()
		var stages: Array = crop["stages"]
		rule.stages.assign(stages)
		var grow_days: int = crop["grow_days"]
		var wither_days: int = crop["wither_days_after_window"]
		rule.ripe = grow_days * calendar.day_length_ticks()
		rule.from_day = window["from"]
		rule.to_day = window["to"]
		rule.wither_day = rule.to_day + wither_days + 1 if rule.to_day >= rule.from_day else 1
		rule.withered_tile = crop["withered_tile"]
		rule.seed_item = crop["seed_item"]
		rule.sow_job = crop["sow_job"]
		rule.harvest_job = crop["harvest_job"]
		var crop_id: String = crop["id"]
		_rules[crop_id] = rule
		for i in rule.stages.size():
			_stage_of_tile[rule.stages[i]] = [crop_id, i]
		_sow_seeds[rule.sow_job] = rule.seed_item
		for kind: String in [rule.sow_job, rule.harvest_job]:
			if kind not in job_kinds:
				job_kinds.append(kind)
	_dirty_cursor = tile_grid.get_dirty_cells_since(0)["next"]
	giver = FarmGiverType.new(get_farm_zones, get_items, view_jobs_of_kinds.bind(job_kinds), submit, passability,
		tile_grid.get_tile, ripe_harvests, sow_open, sow_job_of, _sow_seeds)

## The "farming" tick phase.
func advance() -> void:
	var stream := _tile_grid.get_dirty_cells_since(_dirty_cursor)
	_dirty_cursor = stream["next"]
	if stream["truncated"]:
		reconcile_all()
	else:
		for cell: Vector2i in stream["cells"]:
			_reconcile(cell)
	_grow(_clock.tick)
	giver.advance(_clock.tick)

## Rebuilds the records from the whole map: after decode() and when the dirty stream lost cells.
func reconcile_all() -> void:
	for key: String in crops.keys():
		_reconcile(_tile_of(key))
	for index in _tile_grid.tiles.size():
		if _stage_of_tile.has(_tile_grid.tiles[index]):
			_reconcile(_tile_grid.coord_of(index))
	_dirty_cursor = _tile_grid.get_dirty_cells_since(0)["next"]

## One cell: a stage tile gets a record (growth at its stage's threshold) unless it already
## has one of the same crop; any other tile loses its record.
func _reconcile(cell: Vector2i) -> void:
	var key := _key(cell)
	if not _stage_of_tile.has(_tile_grid.get_tile(cell.x, cell.y)):
		crops.erase(key)
		return
	var stage: Array = _stage_of_tile[_tile_grid.get_tile(cell.x, cell.y)]
	var crop_id: String = stage[0]
	var stage_index: int = stage[1]
	if crops.has(key):
		var record: Dictionary = crops[key]
		if record["crop"] == crop_id:
			return
	var rule: CropRule = _rules[crop_id]
	crops[key] = {"crop": crop_id, "growth": _stage_threshold(rule, stage_index)}

func _grow(tick: int) -> void:
	var day := _calendar.day_of_tick(tick)
	var keys := crops.keys()
	keys.sort()
	for key: String in keys:
		var record: Dictionary = crops[key]
		var rule: CropRule = _rules[record["crop"]]
		var growth: int = record["growth"]
		if growth >= rule.ripe:
			continue
		if day >= rule.wither_day:
			_set_tile(_tile_of(key), rule.withered_tile)
			crops.erase(key)
		elif _in_window(rule, day):
			record["growth"] = growth + 1
			_set_tile(_tile_of(key), _stage_tile(rule, growth + 1))

func _in_window(rule: CropRule, day: int) -> bool:
	return day >= rule.from_day and day <= rule.to_day

## The stage tile shown at growth: the last stage whose threshold growth has reached.
func _stage_tile(rule: CropRule, growth: int) -> String:
	var shown := 0
	for i in rule.stages.size():
		if growth * (rule.stages.size() - 1) >= rule.ripe * i:
			shown = i
	return rule.stages[shown]

func _stage_threshold(rule: CropRule, stage: int) -> int:
	return ceili(float(rule.ripe * stage) / float(rule.stages.size() - 1))

## Writes a stage change through the dirty log (every stage is the crop's own passable tile,
## but mark_dirty() refreshes the cell like any tile change).
func _set_tile(cell: Vector2i, kind: String) -> void:
	var index := _tile_grid.index_of(cell)
	if _tile_grid.tiles[index] == kind:
		return
	_tile_grid.tiles[index] = kind
	_tile_grid.mark_dirty(cell.x, cell.y)

## FarmGiver's harvest list: [tile, the crop's harvest job kind] for every ripe crop, in key order.
func ripe_harvests() -> Array:
	var keys := crops.keys()
	keys.sort()
	var harvests: Array = []
	for key: String in keys:
		var record: Dictionary = crops[key]
		var rule: CropRule = _rules[record["crop"]]
		var growth: int = record["growth"]
		if growth >= rule.ripe:
			harvests.append([_tile_of(key), rule.harvest_job])
	return harvests

## True while crop_id's window is open at tick: FarmGiver sows only then (a crop sown
## outside it would never grow, only wither).
func sow_open(crop_id: String, tick: int) -> bool:
	if not _rules.has(crop_id):
		return false
	var rule: CropRule = _rules[crop_id]
	return _in_window(rule, _calendar.day_of_tick(tick))

## The jobs.json kind that sows crop_id; "" for an unknown crop.
func sow_job_of(crop_id: String) -> String:
	if not _rules.has(crop_id):
		return ""
	var rule: CropRule = _rules[crop_id]
	return rule.sow_job

## {} when (x, y) holds no crop; else {"crop", "growth", "ripe_growth"} (viewer/tests).
func crop_at(x: int, y: int) -> Dictionary:
	var key := _key(Vector2i(x, y))
	if not crops.has(key):
		return {}
	var record: Dictionary = (crops[key] as Dictionary).duplicate()
	var rule: CropRule = _rules[record["crop"]]
	record["ripe_growth"] = rule.ripe
	return record

## The save field this module owns: "crops", [{target, crop, growth}] in key order.
func encode() -> Dictionary:
	var keys := crops.keys()
	keys.sort()
	var list: Array = []
	for key: String in keys:
		var cell := _tile_of(key)
		var record: Dictionary = crops[key]
		list.append({"target": {"x": cell.x, "y": cell.y}, "crop": record["crop"], "growth": record["growth"]})
	return {"crops": list}

## Restores the records, then reconciles them with the decoded tiles (a migrated v4 save's
## sown tiles start from their stage's threshold).
func decode(state: Dictionary) -> void:
	crops = {}
	var list: Array = state.get("crops", [])
	for entry: Dictionary in list:
		var target: Dictionary = entry["target"]
		var x: int = target["x"]
		var y: int = target["y"]
		var crop_id: String = entry["crop"]
		var growth: int = entry["growth"]
		crops[_key(Vector2i(x, y))] = {"crop": crop_id, "growth": growth}
	reconcile_all()

func hash_into(snapshot: Dictionary) -> void:
	if not crops.is_empty():
		snapshot["crops"] = crops

## The crops key, TileGrid's "x,y" format (ADR 045 §2: TileGrid owns every tile key format).
func _key(cell: Vector2i) -> String:
	return TileGridType.comma_key(cell.x, cell.y)

## _key()'s inverse.
func _tile_of(key: String) -> Vector2i:
	return Vector2i(key.get_slice(",", 0).to_int(), key.get_slice(",", 1).to_int())
