class_name ActorVisitor
extends RefCounted

## Visitor component (ADR 012): a non-colony visitor flag (a trader). Data + validate() only,
## no tunables.

static func validate(tunables: Dictionary) -> bool:
	return tunables.is_empty()
