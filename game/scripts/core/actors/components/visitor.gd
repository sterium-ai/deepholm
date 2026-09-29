class_name ActorVisitor
extends RefCounted

## F2 visitor component: marks an actor as a non-colony faction visitor (a
## trader passing through). Data + validate() only -- "Must not change" real
## behaviour in this task (docs/decisions/012-actors-and-components.md, task
## t3). No tunables: presence of the component on an actor definition is
## itself the flag.

static func validate(tunables: Dictionary) -> bool:
	return tunables.is_empty()
