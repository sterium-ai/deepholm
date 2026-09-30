class_name SaveConfig
extends RefCounted

## Single source of truth for autosave cadence. Both autosave_trigger.gd and
## its test read this constant so the interval can never drift between the
## trigger and the test that checks it.
##
## The debug viewer's tick driver (tick_driver.gd) submits
## BASE_TICKS_PER_SECOND * speed world ticks per real second; at the base
## rate of 2 ticks/sec and x1 speed, 600 ticks is five minutes of session
## time between autosaves. The trigger itself never reads wall-clock time --
## this is purely a tick count, and the five-minute framing here is only
## documentation of how it maps to the viewer's own real-time pacing.
const AUTOSAVE_INTERVAL_TICKS := 600
