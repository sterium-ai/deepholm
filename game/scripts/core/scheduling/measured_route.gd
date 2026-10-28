extends "res://scripts/core/routing/route_search.gd"

## Instrument the expansion hook without changing the search algorithm.
var expansions: int = 0
var resume_calls: int = 0

func resume() -> String:
	resume_calls += 1
	var status := super.resume()
	expansions += _last_resume_steps
	return status

func snapshot() -> Dictionary:
	var state := super.snapshot()
	state["expansions"] = expansions
	state["resume_calls"] = resume_calls
	return state

## See RouteSearch.summary(): the counters are constant-size too.
func summary() -> Dictionary:
	var state := super.summary()
	state["expansions"] = expansions
	state["resume_calls"] = resume_calls
	return state

## See RouteSearch.restore(); also restores the instrumentation counters.
func restore(state: Dictionary) -> void:
	super.restore(state)
	expansions = int(state.get("expansions", 0))
	resume_calls = int(state.get("resume_calls", 0))
