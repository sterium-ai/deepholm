extends Node

## Headless-testable autosave trigger (issue #95). Fires
## SaveManager.save_autosave() exactly once per elapsed
## SaveConfig.AUTOSAVE_INTERVAL_TICKS boundary of world ticks -- never at
## tick 0, never twice for the same boundary -- driven purely by the tick
## count passed to check(), never by wall-clock time or frame rate. See
## test_autosave_trigger.gd for the boundary-purity proof.
##
## Also saves before ticks stop, per ADR 003 principle 4 (backgrounding
## suspends ticks; platform callbacks route through the command boundary,
## never mutate core state directly). Three notifications all call the same
## save_autosave() public API used by the per-tick boundary check above --
## no core mutation happens here:
##   - NOTIFICATION_APPLICATION_PAUSED: app backgrounding on Android/iOS.
##   - NOTIFICATION_APPLICATION_FOCUS_OUT: the Web export's only signal for a
##     hidden/backgrounded browser tab. Godot's HTML5 platform layer listens
##     for the DOM `visibilitychange` event and reports it to the engine as a
##     focus-out notification (browsers expose tab visibility as a focus
##     change, not a distinct "paused" state, so NOTIFICATION_APPLICATION_PAUSED
##     never fires on Web). This also fires on desktop when the window loses
##     focus, which is a harmless extra save.
##   - NOTIFICATION_WM_CLOSE_REQUEST: desktop window close.

const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const SaveConfigType = preload("res://scripts/core/persistence/save_config.gd")

signal autosaved(result: Dictionary)

var world: WorldState
var save_manager: SaveManagerType

var _last_boundary: int = 0
var _epoch: int = 0
## New Game (issue #299 round 1) suspends autosaving entirely until the
## player's first explicit Save: without this, an unsaved fresh game ticking
## in the background could rotate into (evict) an existing autosave slot
## from a previous game before the player ever confirmed they wanted to keep
## the new one, contradicting the New Game confirmation dialog's own promise
## that the last save is kept until Save is pressed. See boot.gd's
## _start_new_game()/_on_save_pressed(). Defaults true so ordinary startup
## (a fresh boot, or a loaded continuing game) autosaves exactly as before.
var _enabled: bool = true

func _init(world_ref: WorldState = null, save_manager_ref: SaveManagerType = null) -> void:
	attach(world_ref, save_manager_ref)

## Repoints the trigger at a new world/manager (for example after Load
## replaces the running world) and resyncs the boundary bookkeeping to the
## new world's current tick, so the trigger neither re-fires immediately
## for a boundary the loaded save already crossed nor skips the next one.
## Always re-enables autosaving: attaching to an already-loaded or freshly
## restored world means there is nothing pending to protect, so only
## boot.gd's New Game path (which calls this, then set_enabled(false) right
## after) needs it suspended.
func attach(world_ref: WorldState, save_manager_ref: SaveManagerType, epoch: int = 0) -> void:
	world = world_ref
	save_manager = save_manager_ref
	_epoch = epoch
	_enabled = true
	_last_boundary = _boundary_for(world.get_tick()) if world != null else 0

## Re-enabling resyncs _last_boundary to the current tick (like attach()),
## so a game re-enabled mid-interval (boot.gd's _on_save_pressed()) waits for
## the next real boundary crossing instead of immediately firing a catch-up
## save for every boundary ticked past while suspended.
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if enabled and world != null:
		_last_boundary = _boundary_for(world.get_tick())

func is_enabled() -> bool:
	return _enabled

## Call once per world tick (for example from the tick driver's `ticked`
## signal) with world.get_tick(). Pure function of `tick`: the same
## sequence of tick values always yields the same fire/no-fire sequence,
## regardless of when or how often it is actually called in real time.
## Returns true exactly when this call crossed a new interval boundary and
## attempted an autosave. Boundary bookkeeping only advances when that save
## actually succeeds (matching _save_now() below), so a save that fails here
## is retried on the next tick instead of being silently skipped for the
## remainder of the interval.
func check(tick: int) -> bool:
	if not _enabled:
		return false
	var boundary := _boundary_for(tick)
	if boundary <= _last_boundary:
		return false
	if world == null or save_manager == null:
		_last_boundary = boundary
		return false
	var result := _fire()
	if result.get("ok", false):
		_last_boundary = boundary
	return true

func _notification(what: int) -> void:
	if not _enabled:
		return
	if what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_now()

## Shared by the three lifecycle notifications above: fires an autosave
## immediately regardless of tick-boundary state, then -- only when that
## save actually succeeds -- advances _last_boundary to cover the boundary
## this tick falls in. Without this, a lifecycle save landing exactly on an
## interval boundary (for example a hidden browser tab at tick 600) would
## satisfy that boundary but leave _last_boundary unmoved, so the very next
## check(600) delivered from a tick already queued when the notification
## fired would save a second, redundant time for the same boundary. A
## failed save leaves the bookkeeping untouched so check() still retries the
## boundary on a later tick.
func _save_now() -> void:
	if world == null:
		return
	var result := _fire()
	if result.get("ok", false):
		var boundary := _boundary_for(world.get_tick())
		if boundary > _last_boundary:
			_last_boundary = boundary

func _fire() -> Dictionary:
	if world == null or save_manager == null:
		return {}
	var result: Dictionary = save_manager.save_autosave(world, _epoch)
	autosaved.emit(result)
	return result

func _boundary_for(tick: int) -> int:
	if tick <= 0:
		return 0
	return tick / SaveConfigType.AUTOSAVE_INTERVAL_TICKS
