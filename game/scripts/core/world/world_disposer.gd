class_name WorldDisposer
extends RefCounted

## WorldState.dispose() (A7): frees a world that is being replaced (a load, a New Game).
## The modules reach each other and the façade through bound Callables and back-references,
## so a dropped WorldState is a RefCounted cycle that never frees (bench_save_load's leak
## check). This walks every object reachable from the world through script variables (Objects,
## Callables, and the Arrays/Dictionaries holding them) and then empties each of those
## variables, which breaks every cycle at once. Containers are replaced, never cleared in place,
## so data shared with something that outlives the world (the session ContentRegistry's
## documents) is left as it was; the objects in keep (that registry) are not walked at all.
## A disposed world and its modules are unusable afterwards.

static func dispose(root: Object, keep: Array[Object]) -> void:
	var seen: Dictionary = {}
	for kept in keep:
		if kept != null:
			seen[kept.get_instance_id()] = false
	# Every variable is read before any is reset: a property getter (WorldState._items) reads
	# through another module, which must still be wired when it runs.
	var reached: Array[Object] = []
	var values: Array[Dictionary] = []
	var pending: Array[Object] = [root]
	seen[root.get_instance_id()] = true
	while not pending.is_empty():
		var object: Object = pending.pop_back()
		var read: Dictionary = {}
		for property in _script_variables(object):
			read[property] = object.get(property)
			_collect(read[property], seen, pending)
		reached.append(object)
		values.append(read)
	for i in reached.size():
		for property: String in values[i]:
			_reset(reached[i], property, values[i][property])

static func _script_variables(object: Object) -> Array[String]:
	var names: Array[String] = []
	if object.get_script() == null:
		return names
	for property: Dictionary in object.get_property_list():
		var usage: int = property["usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var name: String = property["name"]
			names.append(name)
	return names

static func _collect(value: Variant, seen: Dictionary, pending: Array[Object]) -> void:
	match typeof(value):
		TYPE_OBJECT:
			var object: Object = value
			if object != null and is_instance_valid(object) and not seen.has(object.get_instance_id()):
				seen[object.get_instance_id()] = true
				pending.append(object)
		TYPE_CALLABLE:
			var callable: Callable = value
			_collect(callable.get_object(), seen, pending)
			for argument: Variant in callable.get_bound_arguments():
				_collect(argument, seen, pending)
		TYPE_ARRAY:
			var array: Array = value
			if array.is_typed() and array.get_typed_builtin() not in [TYPE_OBJECT, TYPE_CALLABLE, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_NIL]:
				return
			for item: Variant in array:
				_collect(item, seen, pending)
		TYPE_DICTIONARY:
			var dictionary: Dictionary = value
			for key: Variant in dictionary:
				_collect(key, seen, pending)
				_collect(dictionary[key], seen, pending)

## Objects to null, Callables to an empty Callable, containers to an empty one of the same type.
static func _reset(object: Object, property: String, value: Variant) -> void:
	match typeof(value):
		TYPE_OBJECT:
			object.set(property, null)
		TYPE_CALLABLE:
			object.set(property, Callable())
		TYPE_ARRAY:
			var empty: Array = (value as Array).duplicate(false)
			empty.clear()
			object.set(property, empty)
		TYPE_DICTIONARY:
			var empty: Dictionary = (value as Dictionary).duplicate(false)
			empty.clear()
			object.set(property, empty)
