extends "res://scripts/core/routing/route_search.gd"

## Instrument the expansion hook without changing the search algorithm.
var expansions: int = 0
var resume_calls: int = 0

func resume() -> String:
	resume_calls += 1
	return super.resume()

func _ordered_neighbors(tile: Vector2i) -> Array[Vector2i]:
	expansions += 1
	return super._ordered_neighbors(tile)

func snapshot() -> Dictionary:
	var state := super.snapshot()
	state["expansions"] = expansions
	state["resume_calls"] = resume_calls
	return state

## See RouteSearch.restore(): also restores the instrumentation counters so a
## restored search reports accurate telemetry deltas on its next resume().
func restore(state: Dictionary) -> void:
	super.restore(state)
	expansions = int(state.get("expansions", 0))
	resume_calls = int(state.get("resume_calls", 0))
