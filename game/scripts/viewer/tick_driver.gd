extends Node

## Translates real elapsed frame time into WorldState.tick() calls per
## second. WorldState itself has no frame-rate dependency: this is the only
## place presentation time influences how many ticks get submitted, and it
## never mutates simulation state beyond calling tick().

const WorldStateType = preload("res://scripts/core/world_state.gd")

signal ticked

enum Speed { PAUSED, X1, X2, X3 }

const BASE_TICKS_PER_SECOND := 2.0

var world: WorldStateType
## Paused by default (issue #300 Goal: "the normal new game starts
## paused"): every world this driver ever attaches to -- the default boot
## world, a fresh New Game, a resumed save -- starts with no ticks advancing
## until the player explicitly presses Play/Step, rather than silently
## running at X1 the instant the scene loads.
var speed: int = Speed.PAUSED

var _accumulator: float = 0.0

func _init(world_ref: WorldStateType) -> void:
	world = world_ref

func _process(delta: float) -> void:
	var multiplier := _speed_multiplier(speed)
	if multiplier <= 0.0:
		return
	_accumulator += delta * BASE_TICKS_PER_SECOND * multiplier
	while _accumulator >= 1.0:
		_accumulator -= 1.0
		world.tick()
		ticked.emit()

func set_speed(new_speed: int) -> void:
	speed = new_speed

## Real seconds a single tick spans at the current speed (issue #364): the
## interpolation clock colonist_sprites.gd's advance() divides its own
## elapsed-since-tile-change time by. 0.0 while paused, matching the "freeze
## interpolation and animation" rule -- never divides by BASE_TICKS_PER_SECOND
## alone, since a paused multiplier of 0 must not fall back to some other rate.
func seconds_per_tick() -> float:
	var multiplier := _speed_multiplier(speed)
	if multiplier <= 0.0:
		return 0.0
	return 1.0 / (BASE_TICKS_PER_SECOND * multiplier)

func pause() -> void:
	speed = Speed.PAUSED

## Advances exactly one tick regardless of the current speed/pause setting.
func step_once() -> void:
	world.tick()
	ticked.emit()

func _speed_multiplier(s: int) -> float:
	match s:
		Speed.X1:
			return 1.0
		Speed.X2:
			return 2.0
		Speed.X3:
			return 3.0
		_:
			return 0.0
