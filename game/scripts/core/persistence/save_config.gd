class_name SaveConfig
extends RefCounted

## Single source of truth for the autosave cadence (autosave_trigger.gd and its test).
## A tick count, never wall-clock: 600 ticks is five minutes at the viewer's x1 speed.
const AUTOSAVE_INTERVAL_TICKS := 600
