class_name ReservationTable
extends RefCounted

## Generic String-keyed reservation ledger (colonist-ai.md 3.4): key -> job id.
## Callers build namespaced keys ("tile:x,y" today; future "item:"/"cell:" keys
## from t3/t4 use the same table without ever colliding with a tile key). This
## module knows nothing about tiles, items or jobs; it only tracks ownership.

var _owners: Dictionary = {}

## Refuses a key already owned by a different job. Re-acquiring a key already
## owned by the same job_id is a no-op success.
func acquire(key: String, job_id: String) -> bool:
	var current := String(_owners.get(key, ""))
	if not current.is_empty() and current != job_id:
		return false
	_owners[key] = job_id
	return true

## Refuses to release a key owned by a different job_id (a blocked/finished
## job must never release another job's reservation).
func release(key: String, job_id: String) -> bool:
	if String(_owners.get(key, "")) != job_id:
		return false
	_owners.erase(key)
	return true

## Releases every key currently owned by job_id, for the release_all toil and
## every terminal job transition. Returns the released keys (sorted, for
## deterministic event emission) so a caller can report exactly what was
## freed, e.g. one reservation_released event per key.
func release_all(job_id: String) -> Array[String]:
	var released: Array[String] = []
	for key in _owners.keys():
		if _owners[key] == job_id:
			released.append(String(key))
	released.sort()
	for key in released:
		_owners.erase(key)
	return released

## "" means the key is unreserved.
func owner(key: String) -> String:
	return String(_owners.get(key, ""))

func is_reserved(key: String) -> bool:
	return _owners.has(key)

## Detached deep copy, matching the read-model convention the rest of
## game/scripts/core/jobs/ already uses (see job_queue.gd getters).
func snapshot() -> Dictionary:
	return _owners.duplicate(true)

## Overwrites the table from a prior snapshot (e.g. save/restore).
func restore(owners: Dictionary) -> void:
	_owners = owners.duplicate(true)
