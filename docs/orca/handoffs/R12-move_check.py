"""R12: checks that the code leaving WorldState is a move, statement by statement.

For every moved function it takes the body from the base's world_state.gd, applies the
mechanical renames listed for it (injected Callables, parameters in place of fields),
drops comment and blank lines, and diffs the result against the new body. The diff has
to be exactly the DECLARED one (compared as a set, since ndiff orders adjacent changes
arbitrarily; every undeclared statement must still match, in order): each declared line
is a statement the move removes (-) or adds (+) on purpose, with the reason next to it.
Anything else is reported.

Five checks:
1. The five tick helpers moved into world/tick_pipeline.gd.
2. tick(): the old body against the new phases expanded in PHASES order (a phase is
   either a TickPipeline method, whose body is inlined, or a sibling's bound method,
   which becomes one call statement).
3. _init(): the old body against the new _init() with every _build_*() call inlined.
4. The content-table and world-seeding helpers moved into content/content_tables.gd and
   worldgen/world_seeding.gd.
5. Every other function still in world_state.gd: same statements as on the base (only
   comments changed, and single-statement bodies may now sit on the signature line).

Usage (repo root):
    python docs/orca/handoffs/R12-move_check.py [base-ref]     # default base: main
"""
import difflib
import re
import subprocess
import sys

WS = "game/scripts/core/world_state.gd"
PIPE = "game/scripts/core/world/tick_pipeline.gd"
TABLES = "game/scripts/core/content/content_tables.gd"
SEED = "game/scripts/core/worldgen/world_seeding.gd"

PIPE_RENAMES = [
    (r"_colonists\.duplicate\(\)", "_roster().duplicate()"),
    (r"(?<![\w.])_colonists\b", "_roster()"),
    (r"(?<![\w.])_route\(", "_route.call("),
]


def git_show(ref, path):
    return subprocess.run(["git", "show", "%s:%s" % (ref, path)], capture_output=True,
                          check=True).stdout.decode("utf-8").replace("\r\n", "\n").split("\n")


def read(path):
    return open(path, encoding="utf-8").read().replace("\r\n", "\n").split("\n")


def functions(lines):
    """name -> code statements (signature first), one-line bodies split off the signature."""
    out, current = {}, None
    for line in lines:
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        match = re.match(r"(static )?func (\w+)\(", line)
        if match:
            current = match.group(2)
            out[current] = []
            one_line = re.match(r"(.*\)(?: -> [^:]+)?:) (.+)$", text)
            if one_line and not text.endswith(":"):
                sig = re.match(r"(.*?\)(?: -> [^:]+)?:) ", text).group(1)
                out[current] += [sig, re.sub(r"\s+#.*$", "", text[len(sig) + 1:].strip())]
                continue
        elif not line.startswith("	"):
            current = None
        if current:
            out[current].append(re.sub(r'\s+#[^"]*$', "", text))
    return out


def body(lines, name, signature=False):
    starts = [k for k, l in enumerate(lines) if re.match(r"(static )?func %s\(" % re.escape(name), l)]
    if len(starts) != 1:
        raise SystemExit("cannot find func %s" % name)
    i = starts[0]
    j = i + 1
    # A signature continued over several lines ends at the line ending in ":".
    while not lines[j - 1].rstrip().endswith(":"):
        j += 1
    head = j
    while j < len(lines) and (lines[j].startswith("\t") or lines[j] == ""):
        j += 1
    return lines[i:j] if signature else lines[head:j]


def code(lines, renames=()):
    out = []
    for line in lines:
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        text = re.sub(r"\s+#.*$", "", text) if not text.startswith('"') else text
        for pattern, repl in renames:
            text = re.sub(pattern, repl, text)
        out.append(text)
    return out


def check(label, expected, got, declared):
    diff = [d for d in difflib.ndiff(expected, got) if d[:1] in "+-"]
    wanted = ["%s %s" % (sign, text) for sign, text, _ in declared]
    ok = sorted(diff) == sorted(wanted)
    print("%-44s %s" % (label, "OK" if ok else "DIFFERS"))
    for sign, text, why in declared:
        print("    declared %s %s    <- %s" % (sign, text, why))
    if not ok:
        for d in diff:
            print("    actual   " + d)
    return ok


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "main"
    old = git_show(base, WS)
    ws, pipe, tables, seed = read(WS), read(PIPE), read(TABLES), read(SEED)
    good = True

    # 1. tick helpers
    for name in ["_colonists_not_combat_owned", "_colonists_not_searching_need", "_committed_jobs",
                 "_scheduler_workers", "_advance_colonists"]:
        good &= check("%s -> tick_pipeline" % name, code(body(old, name), PIPE_RENAMES), code(body(pipe, name)), [])

    # 2. tick() against the phases
    phase_list = re.search(r"_phases = \[(.*?)\]", "\n".join(pipe), re.S).group(1)
    expanded = []
    for entry in [e.strip() for e in phase_list.replace("\n", " ").split(",")]:
        if entry.startswith("_phase_"):
            expanded += code(body(pipe, entry))
        elif entry == "_advance_colonists":
            expanded.append("_advance_colonists()")
        else:
            expanded.append(entry + "()")
    tick_renames = PIPE_RENAMES + [
        (r"var active_site_fetch_jobs_before := ", "_site_fetch_jobs_before = "),
        (r"\bactive_site_fetch_jobs_before\b", "_site_fetch_jobs_before"),
        (r"_calendar\.active_boost", "_current_calendar().active_boost"),
        (r"_calendar_alert_giver\.advance\(_clock\.tick, _calendar, _calendar_alerts_fired\)",
         "_calendar_alert_giver.advance(_clock.tick, _current_calendar(), _alerts_fired())"),
        (r"\bPRIORITY_TICK\b", "_tick_priority"),
    ]
    good &= check("tick() -> TickPipeline.PHASES", code(body(old, "tick"), tick_renames), expanded, [
        ("+", "_site_fetch_jobs_before = {}", "the old local is now a field; cleared once read"),
    ])

    # 3. _init() against the new _init() with the _build_*() helpers inlined
    init = []
    for line in code(body(ws, "_init")):
        call = re.match(r"(_build_\w+)\(", line)
        if call and call.group(1) != "_build_dimension_services":
            init += code(body(ws, call.group(1)))
        else:
            init.append(line)
    tables_renames = [
        (r"_load_object_definitions\(\)", 'ContentTablesType.index_by_field(_content.list("objects"), "kind")'),
        (r"_load_need_definitions\(\)", 'ContentTablesType.index_by_field(_content.list("needs"), "kind")'),
        (r"_load_item_definitions\(\)", 'ContentTablesType.index_by_field(_content.list("items"), "id")'),
        (r"(?<![\w.])_index_by_field\(", "ContentTablesType.index_by_field("),
        (r"_load_need_config\(\)", "ContentTablesType.need_config(_content)"),
        (r"_load_work_ticks\(\)", "ContentTablesType.work_ticks(_content)"),
    ]
    good &= check("_init() -> _init() + _build_*()", code(body(old, "_init"), tables_renames), init, [
        ("-", "_tile_grid.tiles = _generate_map()", "worldgen/world_seeding.gd (check 4)"),
        ("-", "_colonists = _spawn_colonists(_tile_grid.tiles)", "worldgen/world_seeding.gd (check 4)"),
        ("+", "var seeded := WorldSeedingType.seed_world(_seed + GEOGRAPHY_SEED_SALT, _seed + PLACEMENT_SEED_SALT, _tile_grid.width,", "same seeds and inputs"),
        ("+", "_tile_grid.height, _mapgen, _content, _object_table)", "(continuation)"),
        ("+", '_tile_grid.tiles = seeded["tiles"]', "same array the old _generate_map() returned"),
        ("+", '_colonists = seeded["colonists"]', "same array the old _spawn_colonists() returned"),
        ("+", '_spawn_clearing = seeded["clearing"]', "was assigned inside _spawn_colonists()"),
        ("-", 'for job_def in _content.list("jobs"):', "the loop is ContentTables.tool_requirements() (check 4)"),
        ("-", 'var needs_tool := String(job_def.get("needs_tool", ""))', "(loop)"),
        ("-", "if not needs_tool.is_empty():", "(loop)"),
        ("-", 'if not (job_def.has("retry_base_ticks") and job_def.has("retry_cap_ticks")):', "(loop)"),
        ("-", "_fail_startup(\"jobs.json's '%s' entry declares needs_tool but is missing retry_base_ticks/retry_cap_ticks\" % job_def[\"kind\"])", "the message is the function's return value now"),
        ("-", '_needs_tool_by_kind[String(job_def["kind"])] = needs_tool', "dead: written, never read (R11 handoff)"),
        ("-", 'tool_requirements_by_kind[String(job_def["kind"])] = {', "(loop)"),
        ("-", '"kind": needs_tool,', "(loop)"),
        ("-", '"retry_base_ticks": int(job_def["retry_base_ticks"]),', "(loop)"),
        ("-", '"retry_cap_ticks": int(job_def["retry_cap_ticks"]),', "(loop)"),
        ("-", "}", "(loop)"),
        ("+", "var tool_error := ContentTablesType.tool_requirements(_content, tool_requirements_by_kind)", "same loop, same order"),
        ("+", "if not tool_error.is_empty():", "same failure"),
        ("+", "_fail_startup(tool_error)", "same message, same kill"),
    ])

    # 4. content tables and world seeding
    content_renames = [(r"(?<![\w.])_content\b", "content")]
    good &= check("_index_by_field -> ContentTables.index_by_field", code(body(old, "_index_by_field")),
                  code(body(tables, "index_by_field")), [])
    good &= check("_load_work_ticks -> ContentTables.work_ticks", code(body(old, "_load_work_ticks"), content_renames),
                  code(body(tables, "work_ticks")), [])
    good &= check("_load_need_config -> ContentTables.need_config", code(body(old, "_load_need_config"), content_renames),
                  code(body(tables, "need_config")), [])
    seed_renames = [
        (r"_seed \+ GEOGRAPHY_SEED_SALT", "geography_seed"),
        (r"_seed \+ PLACEMENT_SEED_SALT", "placement_seed"),
        (r"_tile_grid\.width", "width"), (r"_tile_grid\.height", "height"),
        (r"(?<![\w.])_mapgen\b", "mapgen"), (r"(?<![\w.])_content\b", "content"),
        (r"(?<![\w.])_object_table\b", "object_table"),
        (r"(?<![\w.])_pending_water_tiles\b", "water_tiles"),
        (r"(?<![\w.])_pending_berry_bush_tiles\b", "berry_bush_tiles"),
    ]
    good &= check("_generate_map -> WorldSeeding._generate_map", code(body(old, "_generate_map"), seed_renames),
                  code(body(seed, "_generate_map")), [
        ("-", "var result := WorldGeneratorType.generate_with_decorations(geography_random, width, height, mapgen)", "same call, returned whole"),
        ("-", 'water_tiles = result["water_tiles"]', "seed_world() reads it from the result"),
        ("-", 'berry_bush_tiles = result["berry_bush_tiles"]', "seed_world() reads it from the result"),
        ("-", 'return result["tiles"]', "seed_world() reads it from the result"),
        ("+", "return WorldGeneratorType.generate_with_decorations(geography_random, width, height, mapgen)", "same call"),
    ])
    good &= check("_spawn_colonists -> WorldSeeding._spawn_colonists", code(body(old, "_spawn_colonists"), seed_renames),
                  code(body(seed, "_spawn_colonists")), [
        ("-", '_spawn_clearing = placement["clearing"]', "returned instead; WorldState assigns it"),
        ("-", "water_tiles = []", "the scratch fields are gone (locals now)"),
        ("-", "berry_bush_tiles = []", "the scratch fields are gone (locals now)"),
        ("-", "return spawned", "returned with the clearing"),
        ("+", 'return {"colonists": spawned, "clearing": placement["clearing"]}', "same values"),
    ])

    # 5. everything that stayed
    old_funcs, new_funcs = functions(old), functions(ws)
    kept = [n for n in old_funcs if n in new_funcs and n not in ("_init", "tick", "_build_dimension_services")]
    changed = [n for n in kept if old_funcs[n] != new_funcs[n]]
    print("%-44s %s" % ("%d unchanged world_state.gd functions" % len(kept), "OK" if not changed else "DIFFERS"))
    for name in changed:
        good = False
        for d in difflib.ndiff(old_funcs[name], new_funcs[name]):
            if d[:1] in "+-":
                print("    %s: %s" % (name, d))
    # _build_dimension_services(): the old body plus the TickPipeline construction.
    dim_old = code(body(old, "_build_dimension_services"), tables_renames)
    dim_new = code(body(ws, "_build_dimension_services"))
    rest = [d for d in difflib.ndiff(dim_old, dim_new) if d[:1] in "+-"]
    dim_ok = all(d.startswith("+ ") for d in rest) and "_tick_pipeline = TickPipelineType.new(" in rest[0]         and dim_new[:len(dim_old)] == dim_old
    print("%-44s %s" % ("_build_dimension_services (+ TickPipeline)", "OK" if dim_ok else "DIFFERS"))
    good &= dim_ok
    removed = sorted(set(old_funcs) - set(new_funcs))
    print("removed from world_state.gd: " + ", ".join(removed))

    # Nothing moved is still defined in WorldState.
    for name in ["_colonists_not_combat_owned", "_colonists_not_searching_need", "_committed_jobs",
                 "_scheduler_workers", "_advance_colonists", "_index_by_field", "_load_work_ticks",
                 "_load_need_config", "_load_object_definitions", "_load_need_definitions",
                 "_load_item_definitions", "_generate_map", "_spawn_colonists"]:
        if any(re.match(r"(static )?func %s\(" % name, l) for l in ws):
            print("still defined in world_state.gd: " + name)
            good = False
    print("R12-move_check: %s" % ("all moves verified" if good else "DIFFERENCES FOUND"))
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
