extends SceneTree

## Scene-free coverage for AutosaveTrigger: the
## per-tick boundary check fires exactly once per elapsed interval, never at
## tick 0, never twice for the same boundary, and is a pure function of the
## tick argument (a byte-for-byte replay of the same tick sequence through a
## fresh instance reproduces the identical fire pattern, proving there is no
## wall-clock or frame-rate dependency). Also covers the platform
## notifications firing an immediate save regardless of tick boundary.

const AutosaveTriggerType = preload("res://scripts/viewer/autosave_trigger.gd")
const SaveConfigType = preload("res://scripts/core/persistence/save_config.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const BASE_DIR := "user://test-autosave-trigger"

## Test-only double for the failed-save retry regression: returns a typed
## write failure for the first `fail_times` calls to save_autosave(), then
## delegates to the real SaveManager so the eventual successful save is
## indistinguishable from a normal one (real rotation, real
## last-known-good bookkeeping).
class _FailingThenSucceedingManager extends "res://scripts/core/persistence/save_manager.gd":
	var _fail_times: int

	func _init(save_dir: String, fail_times: int) -> void:
		super._init(save_dir)
		_fail_times = fail_times

	func save_autosave(world: WorldStateType, epoch: int = 0) -> Dictionary:
		if _fail_times > 0:
			_fail_times -= 1
			return {"ok": false, "code": "write_failed", "message": "simulated failure for test"}
		return super.save_autosave(world, epoch)

var failed := false

func _init() -> void:
	_cleanup_dir(BASE_DIR)
	_cleanup_dir(BASE_DIR + "-replay")
	_cleanup_dir(BASE_DIR + "-platform")
	_cleanup_dir(BASE_DIR + "-notify-boundary")
	_cleanup_dir(BASE_DIR + "-retry")

	_cleanup_dir(BASE_DIR + "-disabled")

	_check_boundary_fires_once_per_interval()
	_check_boundary_is_pure_function_of_tick()
	_check_platform_notifications_save_immediately()
	_check_notification_at_boundary_prevents_double_fire()
	_check_failed_save_retries_at_same_boundary()
	_check_disabled_trigger_never_fires_and_resumes_when_reenabled()

	_cleanup_dir(BASE_DIR)
	_cleanup_dir(BASE_DIR + "-replay")
	_cleanup_dir(BASE_DIR + "-platform")
	_cleanup_dir(BASE_DIR + "-notify-boundary")
	_cleanup_dir(BASE_DIR + "-retry")
	_cleanup_dir(BASE_DIR + "-disabled")
	if failed:
		quit(1)
	else:
		print("test_autosave_trigger: PASS")
		quit()

## Drives a trigger tick-by-tick across two interval boundaries and checks
## the exact fire/no-fire sequence: never at tick 0, no fire anywhere strictly
## between boundaries, exactly one fire at each boundary, and a repeated
## check() call at an already-fired boundary never fires again.
func _check_boundary_fires_once_per_interval() -> void:
	var manager := SaveManagerType.new(BASE_DIR)
	var world := WorldStateType.new(9001)
	var trigger := AutosaveTriggerType.new(world, manager)
	var interval := SaveConfigType.AUTOSAVE_INTERVAL_TICKS

	_expect(not trigger.check(0), "must never fire at tick 0")

	for _i in range(interval - 1):
		world.tick()
		_expect(not trigger.check(world.get_tick()),
			"must not fire before the first interval elapses (tick %d)" % world.get_tick())

	world.tick() # tick == interval
	_expect(world.get_tick() == interval, "test fixture must reach exactly one interval")
	_expect(trigger.check(world.get_tick()), "must fire exactly at the first interval boundary")
	_expect(not trigger.check(world.get_tick()), "must never fire twice for the same boundary")

	var good = manager.get_last_known_good()
	_expect(good != null and int(good["tick"]) == interval,
		"the fired autosave must record the boundary tick, got %s" % [good])

	for _i in range(interval - 1):
		world.tick()
		_expect(not trigger.check(world.get_tick()),
			"must not re-fire before the second interval elapses (tick %d)" % world.get_tick())

	world.tick() # tick == interval * 2
	_expect(trigger.check(world.get_tick()), "must fire again at the second interval boundary")
	good = manager.get_last_known_good()
	_expect(good != null and int(good["tick"]) == interval * 2,
		"the second autosave must record the second boundary tick, got %s" % [good])

## Replays the identical tick sequence (0 .. 2*interval) through a fresh
## trigger/manager pair and checks the fire/no-fire result at every single
## tick matches an expectation computed purely from that tick number. This
## is the pure-function-of-tick-count proof: check() never consults
## OS.get_ticks_msec(), Time, or _process's delta, so nothing here needs to
## run in real time for the two runs to agree.
func _check_boundary_is_pure_function_of_tick() -> void:
	var interval := SaveConfigType.AUTOSAVE_INTERVAL_TICKS
	var dir := BASE_DIR + "-replay"
	var manager := SaveManagerType.new(dir)
	var world := WorldStateType.new(9001)
	var trigger := AutosaveTriggerType.new(world, manager)

	var fired: Array[bool] = [trigger.check(0)]
	for _i in range(interval * 2):
		world.tick()
		fired.append(trigger.check(world.get_tick()))

	var expected: Array[bool] = [false]
	for tick in range(1, interval * 2 + 1):
		expected.append(tick == interval or tick == interval * 2)

	_expect(fired == expected,
		"fire pattern must be a pure function of tick count, expected %s got %s" % [expected, fired])

## NOTIFICATION_APPLICATION_PAUSED (mobile backgrounding),
## NOTIFICATION_APPLICATION_FOCUS_OUT (the Web export's signal for a hidden
## browser tab -- Godot's HTML5 platform layer reports the DOM
## `visibilitychange` event this way, since browsers have no distinct
## "paused" state), and NOTIFICATION_WM_CLOSE_REQUEST (desktop window close)
## must each save immediately, independent of where the tick count sits
## relative to the next interval boundary.
func _check_platform_notifications_save_immediately() -> void:
	var dir := BASE_DIR + "-platform"
	var manager := SaveManagerType.new(dir)
	var world := WorldStateType.new(9002)
	world.tick()
	world.tick()
	world.tick() # tick == 3, far from any interval boundary
	var trigger := AutosaveTriggerType.new(world, manager)

	trigger._notification(NOTIFICATION_APPLICATION_PAUSED)
	var good = manager.get_last_known_good()
	_expect(good != null and int(good["tick"]) == 3,
		"NOTIFICATION_APPLICATION_PAUSED must save immediately, got %s" % [good])

	world.tick() # tick == 4
	trigger._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	good = manager.get_last_known_good()
	_expect(good != null and int(good["tick"]) == 4,
		"NOTIFICATION_APPLICATION_FOCUS_OUT must save immediately, got %s" % [good])

	world.tick() # tick == 5
	trigger._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	good = manager.get_last_known_good()
	_expect(good != null and int(good["tick"]) == 5,
		"NOTIFICATION_WM_CLOSE_REQUEST must save immediately, got %s" % [good])

## Regression: a lifecycle notification landing
## exactly on an interval boundary (e.g. tab-hidden or window-close at tick
## 600) must satisfy that boundary itself, so a check() call for the same
## tick afterward -- which can happen if a tick signal was already queued
## when the notification fired -- does not fire a second, redundant
## autosave for the boundary the notification already covered.
func _check_notification_at_boundary_prevents_double_fire() -> void:
	var dir := BASE_DIR + "-notify-boundary"
	var manager := SaveManagerType.new(dir)
	var world := WorldStateType.new(9003)
	var interval := SaveConfigType.AUTOSAVE_INTERVAL_TICKS
	# Attach at tick 0, matching normal viewer wiring, so _last_boundary
	# starts at 0 instead of being pre-synced to the boundary below by
	# attach() itself -- that pre-sync is exactly what would mask this
	# regression if the trigger were constructed after the ticking loop.
	var trigger := AutosaveTriggerType.new(world, manager)
	# A single-element Array, not a plain int: GDScript lambdas capture outer
	# local variables by value at creation time, so `fire_count += 1` inside
	# the lambda would silently mutate a private copy and never update the
	# outer variable read below. Array is a reference type, so mutating its
	# contents from inside the lambda is visible here too.
	var fire_count := [0]
	trigger.autosaved.connect(func(_result: Dictionary): fire_count[0] += 1)

	for _i in range(interval):
		world.tick()
	_expect(world.get_tick() == interval, "test fixture must reach exactly one interval")

	trigger._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_expect(fire_count[0] == 1, "lifecycle notification at the boundary must save once, got %d fires" % fire_count[0])

	_expect(not trigger.check(world.get_tick()),
		"check() at the boundary a lifecycle save already covered must not fire again")
	_expect(fire_count[0] == 1,
		"check() must not cause a second save for a boundary the notification already satisfied, got %d fires" % fire_count[0])

## A save that fails must not permanently forfeit its boundary: check() must
## keep retrying on later ticks within the same interval window until a save
## actually succeeds, at which point the boundary is finally satisfied and
## no further retries occur.
func _check_failed_save_retries_at_same_boundary() -> void:
	var dir := BASE_DIR + "-retry"
	var manager := _FailingThenSucceedingManager.new(dir, 2)
	var world := WorldStateType.new(9004)
	var interval := SaveConfigType.AUTOSAVE_INTERVAL_TICKS
	# Attach at tick 0 (see the comment in the notification-boundary check
	# above): constructing the trigger after ticking to `interval` would let
	# attach() pre-sync _last_boundary to that boundary and make check()
	# return false before ever attempting a save.
	var trigger := AutosaveTriggerType.new(world, manager)
	# See the comment on the equivalent fire_count in
	# _check_notification_at_boundary_prevents_double_fire above: this must be
	# a reference type, not a plain int, for the lambda's mutation to be
	# visible to the assertions below.
	var fire_count := [0]
	trigger.autosaved.connect(func(_result: Dictionary): fire_count[0] += 1)

	for _i in range(interval):
		world.tick()
	_expect(world.get_tick() == interval, "test fixture must reach exactly one interval")

	_expect(trigger.check(world.get_tick()), "first attempt at the boundary must still count as fired")
	_expect(manager.get_last_known_good() == null, "a failed save must not record a last-known-good")
	_expect(fire_count[0] == 1, "first attempt must have called save_autosave once")

	world.tick() # still short of the next interval
	_expect(trigger.check(world.get_tick()), "boundary must retry on the next tick after a failure")
	_expect(manager.get_last_known_good() == null, "second failed save must still not record a last-known-good")

	world.tick()
	_expect(trigger.check(world.get_tick()), "third attempt must retry and finally succeed")
	var good = manager.get_last_known_good()
	_expect(good != null and int(good["tick"]) == interval + 2,
		"the successful retry must record the tick it actually saved at, got %s" % [good])

	_expect(not trigger.check(world.get_tick()),
		"once the boundary succeeds, further check() calls at the same boundary must not fire again")
	_expect(fire_count[0] == 3, "no further saves should occur once the boundary succeeded, got %d fires" % fire_count[0])

## New Game suspends autosaving until the player's first
## explicit Save (boot.gd's _start_new_game()/_on_save_pressed()), so an
## unsaved fresh game ticking in the background never silently rotates into
## an existing autosave slot. While disabled, neither check() nor a lifecycle
## notification may fire; re-enabling resumes normal boundary behavior on the
## very next check() without a spurious catch-up fire for boundaries crossed
## while disabled.
func _check_disabled_trigger_never_fires_and_resumes_when_reenabled() -> void:
	var dir := BASE_DIR + "-disabled"
	var manager := SaveManagerType.new(dir)
	var world := WorldStateType.new(9005)
	var interval := SaveConfigType.AUTOSAVE_INTERVAL_TICKS
	var trigger := AutosaveTriggerType.new(world, manager)
	_expect(trigger.is_enabled(), "a freshly attached trigger must be enabled by default")

	trigger.set_enabled(false)
	_expect(not trigger.is_enabled(), "set_enabled(false) must be reflected by is_enabled()")

	for _i in range(interval * 2):
		world.tick()
	_expect(not trigger.check(world.get_tick()), "check() must never fire while disabled, even past a boundary")
	trigger._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_expect(manager.get_last_known_good() == null, "no lifecycle notification may save while disabled")

	trigger.set_enabled(true)
	world.tick() # tick == interval*2 + 1, still short of the next boundary
	_expect(not trigger.check(world.get_tick()), "re-enabling must not spuriously fire for a boundary already passed while disabled")
	for _i in range(interval - 1):
		world.tick()
	_expect(trigger.check(world.get_tick()), "re-enabled trigger must fire normally at the next real boundary")
	var good = manager.get_last_known_good()
	_expect(good != null, "the re-enabled trigger's fire must actually save")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
