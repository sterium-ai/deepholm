extends SceneTree

## A0 benchmark: ContentRegistry load time (read + parse + validate +
## cross-check + freeze, game/scripts/core/content/content_registry.gd) for
## the real bundle and for synthetic bundles with K extra items and K extra
## objects (copies of real entries under new ids, written to user://), to
## see how load time grows towards "hundreds of content kinds".
## The real-bundle number is also what every StateCodec content-version
## lookup (state_codec.gd, ContentRegistryType.new().version()) and every
## SaveIO validation (save_io.gd, ContentRegistryType.new().document("mapgen"))
## pays, since both build a fresh registry per call.
##
## Evidence, not a gate: always exits 0. Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_content_load.gd

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

const REAL_RUNS := 5
const SYNTHETIC_SIZES := [100, 1000, 5000]
const SCHEMA_DIR := "res://content/schemas/"

func _init() -> void:
	print(BenchCommon.header("bench_content_load"))
	var samples: Array = []
	var registry: ContentRegistryType
	for i in REAL_RUNS:
		var t := Time.get_ticks_usec()
		registry = ContentRegistryType.new()
		samples.append(Time.get_ticks_usec() - t)
	var real_bytes := _bundle_bytes("res://content/")
	var real_stats := BenchCommon.stats_ms(samples)
	print("bench_content_load: real bundle (%d bytes, %d items, %d objects) valid=%s load %s" % [
		real_bytes, registry.list("items").size(), registry.list("objects").size(),
		registry.is_valid(), BenchCommon.format_stats(real_stats)])
	var real_row := {"bytes": real_bytes, "items": registry.list("items").size(),
		"objects": registry.list("objects").size(), "valid": registry.is_valid(),
		"load ms": "%.2f" % real_stats["mean"]}
	real_row.merge(BenchCommon.stats_values(real_stats))
	BenchCommon.row("bench_content_load", "load", "real bundle", real_row)
	for size in SYNTHETIC_SIZES:
		var dir := _write_synthetic_bundle(int(size))
		var t := Time.get_ticks_usec()
		var synthetic := ContentRegistryType.new(dir, SCHEMA_DIR)
		var usec := Time.get_ticks_usec() - t
		var bytes := _bundle_bytes(dir)
		print("bench_content_load: synthetic +%d items +%d objects (%d bytes) valid=%s load=%.1fms (%.1f us per added entry) error=%s" % [
			size, size, bytes, synthetic.is_valid(), usec / 1000.0, float(usec) / (2 * int(size)),
			synthetic.get_error()])
		BenchCommon.row("bench_content_load", "load", "synthetic +%d items +%d objects" % [size, size], {
			"bytes": bytes, "items": synthetic.list("items").size(), "objects": synthetic.list("objects").size(),
			"valid": synthetic.is_valid(), "load ms": "%.1f" % (usec / 1000.0),
			"us per added entry": "%.1f" % (float(usec) / (2 * int(size)))})
	var objects_text := FileAccess.get_file_as_string(_write_synthetic_bundle(5000) + "objects.json")
	var t := Time.get_ticks_usec()
	var parsed = JSON.parse_string(objects_text)
	var parse_usec := Time.get_ticks_usec() - t
	print("bench_content_load: for comparison, Godot's native JSON.parse_string of the +5000 objects.json: %.1fms (parsed=%s)" % [
		parse_usec / 1000.0, parsed != null])
	BenchCommon.row("bench_content_load", "load", "native JSON.parse_string of the +5000 objects.json", {
		"bytes": objects_text.to_utf8_buffer().size(), "valid": parsed != null, "load ms": "%.1f" % (parse_usec / 1000.0)})
	print("bench_content_load: done")
	quit(0)

## Copies every res://content/*.json into user://bench_content_<size>/ and
## appends `size` items (copies of "stone") and `size` objects (copies of
## "chair") with fresh ids.
func _write_synthetic_bundle(size: int) -> String:
	var dir := "user://bench_content_%d/" % size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for file_name in DirAccess.get_files_at("res://content/"):
		if not file_name.ends_with(".json"):
			continue
		var text := FileAccess.get_file_as_string("res://content/" + file_name)
		var data = JSON.parse_string(text)
		if file_name == "items.json":
			var template: Dictionary = _find(data["items"], "id", "stone")
			for i in size:
				var entry := template.duplicate(true)
				entry["id"] = "bench_item_%d" % i
				data["items"].append(entry)
			text = _stringify_ints(data)
		elif file_name == "objects.json":
			var template: Dictionary = _find(data["objects"], "kind", "chair")
			for i in size:
				var entry := template.duplicate(true)
				entry["kind"] = "bench_object_%d" % i
				data["objects"].append(entry)
			text = _stringify_ints(data)
		var out := FileAccess.open(dir + file_name, FileAccess.WRITE)
		out.store_string(text)
		out.close()
	return dir

## JSON.stringify() writes every number as a float ("3.0"); the registry's
## schema needs integers to stay integers, so whole floats are written back
## without the fraction.
func _stringify_ints(data) -> String:
	return JSON.stringify(_ints(data), "  ")

func _ints(value):
	match typeof(value):
		TYPE_FLOAT:
			return int(value) if value == floor(value) else value
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[key] = _ints(value[key])
			return out
		TYPE_ARRAY:
			var out := []
			for item in value:
				out.append(_ints(item))
			return out
	return value

func _find(entries: Array, field: String, id: String) -> Dictionary:
	for entry in entries:
		if String(entry.get(field, "")) == id:
			return entry
	return {}

func _bundle_bytes(dir: String) -> int:
	var total := 0
	for file_name in DirAccess.get_files_at(dir):
		if file_name.ends_with(".json"):
			total += FileAccess.get_file_as_bytes(dir + file_name).size()
	return total
