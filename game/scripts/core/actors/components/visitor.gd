class_name ActorVisitor
extends RefCounted

## F2 visitor component: marks an actor as a non-colony faction visitor (a
## trader passing through). Data + validate() only; it adds no behaviour
## of its own (docs/decisions/012-actors-and-components.md). No tunables:
## presence of the component on an actor definition is itself the flag.

static func validate(tunables: Dictionary) -> bool:
	return tunables.is_empty()
