class_name ActorMover
extends RefCounted

## F2 mover component (docs/architecture/foundation-for-breadth.md, docs/
## decisions/012-actors-and-components.md): route + speed. Per-instance state
## lives at the actor's own "route" key, the same field a pre-F2 colonist has
## always carried, so an existing colonist's shape needs no new key for this
## component. Tunables (content/actors.json): {"speed": int >= 1}.
##
## Data + validate() only, like combat/wild/visitor -- movement
## execution stays owned by ToilExecutor/GlobalAssignment against the real
## route shape (job_id/path/step/move_ticks_remaining). This component must
## not add a second, independent movement algorithm against an invented route
## shape; see docs/decisions/012-actors-and-components.md.

static func validate(tunables: Dictionary) -> bool:
	return int(tunables.get("speed", 0)) >= 1
