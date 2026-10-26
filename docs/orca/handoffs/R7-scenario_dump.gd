extends SceneTree

## R7 byte-identity probe: a trade-heavy scenario. A stockpile zone is filled with one
## unit of every non-tool item kind; trader_visit incidents are spawned every 60 ticks.
## Offers are handled in rotation: accepted at once, accepted after the stock of the
## wanted kind was emptied (blocked_missing_input), refused (left to despawn), plus
## malformed and unknown-trader accept_trade commands. The world is saved every 150
## ticks and reloaded into a side copy (offers are not persisted, so a pending one is
## gone there); play continues on the original, because a reloaded world has incidents off.
## Every tick traces the pending offers, every actor's inventory, the item list and
## state_hash(). Writes saves, trace, results and events to the directory given as the
## first user argument. Run before and after the refactor and compare the files.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R7.md:
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const ZONE_ORIGIN := Vector2i(20, 20)
const ZONE_SIZE := 6

var _n := 0
var _handled := {}
var _offers_seen := 0

func _cmd(world, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return {"actor": "player", "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

func _item_kinds(world) -> Array:
	var kinds: Array = []
	for entry in world._content.list("items"):
		var id := String(entry["id"])
		if not world.is_tool_kind(id):
			kinds.append(id)
	kinds.sort()
	return kinds

func _stock(world) -> void:
	var i := 0
	for kind in _item_kinds(world):
		var tile := ZONE_ORIGIN + Vector2i(i % ZONE_SIZE, i / ZONE_SIZE)
		world._item_table.spawn_item(kind, tile.x, tile.y)
		i += 1

func _remove_all_of(world, kind: String) -> void:
	for item in world.get_items():
		if String(item["kind"]) == kind:
			world._item_table.remove_stockpiled_item_unit(String(item["id"]))

func _trace_line(world) -> Dictionary:
	var inventories := {}
	for actor in world.get_colonists():
		if actor.get("inventory") is Dictionary:
			inventories[String(actor["id"])] = actor["inventory"]
	return {"tick": world.get_tick(), "offers": world.get_pending_trade_offers(), "inventories": inventories,
		"items": world.get_items(), "hash": world.state_hash()}

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	for t in range(from_tick, to_tick):
		if t % 45 == 0:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"})))
		if t % 90 == 0:
			_stock(world)
		if t % 70 == 0:
			results.append(world.apply(_cmd(world, "accept_trade", {})))
			results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": 7})))
			results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": "nobody"})))
			results.append(world.preview(_cmd(world, "accept_trade", {"trader_id": "nobody"})))
		for offer in world.get_pending_trade_offers():
			var trader_id := String(offer["trader_id"])
			if _handled.has(trader_id):
				continue
			_handled[trader_id] = true
			match _offers_seen % 3:
				0:
					results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": trader_id})))
				1:
					_remove_all_of(world, String(offer["want_item"]))
					results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": trader_id})))
					_stock(world)
					results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": trader_id})))
				2:
					pass # refused: the trader leaves on its own wait
			_offers_seen += 1
		if t % 15 == 0 and not world.get_pending_trade_offers().is_empty():
			# Save/load with an offer in flight: the reloaded side copy has none.
			var mid: Dictionary = world.to_save_state()
			var side = WorldStateType.from_save_state(mid)
			results.append({"tick": t, "pending_live": world.get_pending_trade_offers(), "pending_reloaded": side.get_pending_trade_offers(),
				"hash_live": world.state_hash(), "hash_reloaded": side.state_hash()})
		world.tick()
		trace.append(_trace_line(world))
	# A late accept for every trader ever seen (departed or not).
	for trader_id in _handled.keys():
		results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": trader_id})))

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(777, 10, 48, 48, true)
	var results: Array = []
	var trace: Array = []
	var events: Array = []
	var io: Array = []
	var c0: Dictionary = world.get_colonists()[0]
	results.append(world.apply(_cmd(world, "zone_add", {"x": ZONE_ORIGIN.x, "y": ZONE_ORIGIN.y, "width": ZONE_SIZE, "height": ZONE_SIZE})))
	results.append({"colonist0": [int(c0["x"]), int(c0["y"])]})
	for leg in 6:
		_play(world, results, trace, leg * 150, (leg + 1) * 150)
		var state: Dictionary = world.to_save_state()
		_write(out_dir.path_join("state_%d.json" % ((leg + 1) * 150)), JSON.stringify(state, "\t"))
		io.append(SaveIOType.write_atomic(out_dir.path_join("save_%d.json" % ((leg + 1) * 150)), state).get("ok"))
		events.append(world.get_events())
		results.append({"pending_at_save": world.get_pending_trade_offers(), "hash": world.state_hash()})
		# Play continues on the original world (a reloaded world has incidents off).
		var loaded = WorldStateType.from_save_state(state)
		results.append({"pending_after_load": loaded.get_pending_trade_offers(), "hash": loaded.state_hash(),
			"resaved_equal": JSON.stringify(loaded.to_save_state()) == JSON.stringify(state)})
	_write(out_dir.path_join("events.json"), JSON.stringify(events, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io))
	var applied := 0
	var rejected := {}
	var offer_events := 0
	for r in results:
		if r.has("ok"):
			if r["ok"]:
				applied += 1
			else:
				var reason := String((r["rejection"] as Dictionary).get("reason", "?"))
				rejected[reason] = int(rejected.get(reason, 0)) + 1
	for leg_events in events:
		for e in leg_events:
			if String(e["type"]) == "trade_offer":
				offer_events += 1
	print("scenario_dump: results=%d applied=%d rejected=%s traders=%d trade_offer_events=%d io=%s hash=%d" % [
		results.size(), applied, JSON.stringify(rejected), _handled.size(), offer_events, str(io), world.state_hash()])
	quit(0)
