class_name ActorCombat
extends RefCounted

## F2 combat component: attack, damage, cooldown. Data + validate() only;
## it does not drive combat behaviour (docs/decisions/
## 012-actors-and-components.md). Tunables (content/actors.json):
## {"attack": int >= 0, "damage": int >= 0, "cooldown": int >= 1}.

static func validate(tunables: Dictionary) -> bool:
	if not (tunables.get("attack") is int) or int(tunables["attack"]) < 0:
		return false
	if not (tunables.get("damage") is int) or int(tunables["damage"]) < 0:
		return false
	if not (tunables.get("cooldown") is int) or int(tunables["cooldown"]) < 1:
		return false
	return true

## The per-instance state a freshly spawned actor with this component starts
## with: {"attack", "damage", "cooldown", "cooldown_remaining"}.
static func build(tunables: Dictionary) -> Dictionary:
	return {
		"attack": int(tunables.get("attack", 0)),
		"damage": int(tunables.get("damage", 0)),
		"cooldown": int(tunables.get("cooldown", 1)),
		"cooldown_remaining": 0,
	}
