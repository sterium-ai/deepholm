class_name ContentTables
extends RefCounted

## Static lookups WorldState builds once from ContentRegistry at construction:
## entries re-indexed by a field, work ticks, the shared need config and the
## per-kind tool requirements. Pure functions, no state.

## Re-indexes ContentRegistry.list()'s frozen entries by field, deep-duplicated so
## the registry's bundle stays immutable while callers mutate copies.
static func index_by_field(entries: Array, field: String) -> Dictionary:
	var indexed: Dictionary = {}
	for entry in entries:
		var entry_dict: Dictionary = entry
		indexed[String(entry_dict[field])] = entry_dict.duplicate(true)
	return indexed

## job kind -> work-toil ticks, for the kinds that declare one.
static func work_ticks(content: ContentRegistry) -> Dictionary:
	var ticks: Dictionary = {}
	for job in content.list("jobs"):
		if job.has("work_ticks"):
			ticks[String(job["kind"])] = int(job["work_ticks"])
	return ticks

## needs.json repeats full/job_priority/retry_base_ticks/retry_cap_ticks on every
## entry rather than once at the root; any entry carries the same value.
static func need_config(content: ContentRegistry) -> Dictionary:
	return content.list("needs")[0]

## Fills job kind -> {"kind","retry_base_ticks","retry_cap_ticks"} (JobQueue's tool
## gate, through ToilBindings). Returns the fatal content error, or "".
static func tool_requirements(content: ContentRegistry, tool_requirements_by_kind: Dictionary) -> String:
	for job_def in content.list("jobs"):
		var needs_tool := String(job_def.get("needs_tool", ""))
		if not needs_tool.is_empty():
			if not (job_def.has("retry_base_ticks") and job_def.has("retry_cap_ticks")):
				return "jobs.json's '%s' entry declares needs_tool but is missing retry_base_ticks/retry_cap_ticks" % job_def["kind"]
			tool_requirements_by_kind[String(job_def["kind"])] = {
				"kind": needs_tool,
				"retry_base_ticks": int(job_def["retry_base_ticks"]),
				"retry_cap_ticks": int(job_def["retry_cap_ticks"]),
			}
	return ""
