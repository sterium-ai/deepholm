class_name CropContent
extends RefCounted

## crops.json's cross-references (ContentRegistry runs it with the other reference checks):
## every stage and the withered tile name a tiles.json id, the seed an items.json id, and
## sow_job/harvest_job a jobs.json kind. The window is not checked against calendar.json: a
## calendar without it (a scenario's, ADR 057, or a content copy with other windows) leaves the
## crop no season, which FarmSystem handles. The crop's jobs
## must do its work: the sow job's effects consume the crop's seed and set its first stage, the
## harvest job's require its last stage; and no tile is a stage of two crops (a stage tile
## names its crop). Pure and static, like the registry's own checks.

## "" when every reference resolves (or there is no crops.json); else the first failure.
static func check(raw_by_kind: Dictionary) -> String:
	if not raw_by_kind.has("crops"):
		return ""
	var known: Dictionary = {}
	for kind: String in ["tiles", "items"]:
		var document: Dictionary = raw_by_kind[kind]
		for entry: Dictionary in (document[kind] as Array):
			known["%s:%s" % [kind, entry["id"]]] = true
	var effects_of: Dictionary = {}
	var jobs: Dictionary = raw_by_kind["jobs"]
	for job: Dictionary in (jobs["jobs"] as Array):
		known["jobs:%s" % job["kind"]] = true
		effects_of[job["kind"]] = job.get("effects", {})
	var stage_owner: Dictionary = {}
	var crops: Dictionary = raw_by_kind["crops"]
	for crop: Dictionary in (crops["crops"] as Array):
		var crop_id: String = crop["id"]
		var stages: Array = crop["stages"]
		var refs: Array[String] = ["items:%s" % crop["seed_item"], "tiles:%s" % crop["withered_tile"],
			"jobs:%s" % crop["sow_job"], "jobs:%s" % crop["harvest_job"]]
		for stage: String in stages:
			refs.append("tiles:%s" % stage)
		for ref in refs:
			if not known.has(ref):
				return "crop '%s' names an unknown %s id '%s'" % [crop_id, ref.get_slice(":", 0), ref.get_slice(":", 1)]
		for stage: String in stages:
			if stage_owner.has(stage):
				return "crop '%s' reuses stage tile '%s' of crop '%s'" % [crop_id, stage, stage_owner[stage]]
			stage_owner[stage] = crop_id
		var sow: Dictionary = effects_of[crop["sow_job"]]
		if sow.get("consumes", "") != crop["seed_item"] or sow.get("set_tile", "") != stages[0]:
			return "crop '%s' sow_job '%s' must consume '%s' and set_tile '%s'" % [crop_id, crop["sow_job"], crop["seed_item"], stages[0]]
		var harvest: Dictionary = effects_of[crop["harvest_job"]]
		if harvest.get("requires_tile", "") != stages[stages.size() - 1]:
			return "crop '%s' harvest_job '%s' must require tile '%s'" % [crop_id, crop["harvest_job"], stages[stages.size() - 1]]
	return ""
