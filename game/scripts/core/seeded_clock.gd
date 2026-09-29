class_name SeededClock
extends RefCounted

var tick_rate: int
var tick: int = 0

func _init(p_tick_rate: int = 10) -> void:
	assert(p_tick_rate > 0)
	tick_rate = p_tick_rate

func advance(steps: int = 1) -> void:
	assert(steps >= 0)
	tick += steps

func seconds() -> float:
	return float(tick) / float(tick_rate)

