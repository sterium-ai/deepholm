class_name ActorMover
extends RefCounted

## Mover component (ADR 012): route + speed on the existing "route" key. Data + validate() only:
## movement stays in ToilExecutor/GlobalAssignment, never a second algorithm here.
## Tunables: {"speed": int >= 1}.

static func validate(tunables: Dictionary) -> bool:
	return int(tunables.get("speed", 0)) >= 1
