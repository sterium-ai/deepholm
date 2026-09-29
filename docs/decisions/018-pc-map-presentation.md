# ADR 018: Clipped PC map camera and explicit designation tools

- Status: accepted for issue #298 (PC map milestone)
- Date: 2026-09-21
- Scope: presentation only

The previous whole-window scroll moved map and controls together and a default
Dig tool made ordinary map navigation submit orders. Separate the fixed HUD
from a clipped camera Control. Use the rendered map child's inverse transform
for all input conversion, including preview and confirmation.

Navigation is the initial mode. Designation requires an explicitly selected
tool; pan, Escape and HUD interactions cannot accidentally submit or cancel
gameplay orders. Temporary grids communicate valid/invalid targets, while
pending orders use subtle fills. Read preview validity by applying existing
commands to an isolated snapshot rather than duplicating simulation rules.

This implements the camera/order separation in ADR 003. Validation is
temporarily PC-only by project decision; it does not remove mobile from
the future vision. The implementation uses the existing presentation extension
point, preserves the single work engine and existing labour controls, and adds
no persistent state or schema migration. No terrain-art finishing is included.

The behavioral contract and acceptance commands are in
[map-experience.md](../architecture/map-experience.md); GUI event tests and
rendered captures accompany the change.
