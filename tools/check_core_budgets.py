"""Checks docs/architecture/core-budgets.json against every .gd file under game/scripts/core.

The rule: no file above max_file_lines (total lines) and no function above
max_function_lines (code lines from a func declaration to the next one, comment and
blank lines excluded -- the FuncLines column of tools/measure_core.ps1). Files with an
older, stricter cap keep it (stricter_file_caps). The listed exceptions are frozen at a
cap of their own, and an exception that the code no longer needs is an error, so the
list only shrinks.

Usage: python tools/check_core_budgets.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "game" / "scripts" / "core"
FUNC = re.compile(r"^(static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)")


def measure(path: Path) -> tuple[int, dict[str, int]]:
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    functions: dict[str, int] = {}
    current = ""
    for line in lines:
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        match = FUNC.match(text)
        if match:
            current = match.group(2)
            functions[current] = 0
        if current:
            functions[current] += 1
    return len(lines), functions


def main() -> int:
    budgets = json.loads((ROOT / "docs" / "architecture" / "core-budgets.json").read_text(encoding="utf-8"))
    max_file = int(budgets["max_file_lines"])
    max_func = int(budgets["max_function_lines"])
    # Each exception is {"cap": N, "until": "<task that removes it>"}.
    file_exceptions: dict[str, int] = {k: int(v["cap"]) for k, v in budgets["file_exceptions"].items()}
    func_exceptions: dict[str, int] = {k: int(v["cap"]) for k, v in budgets["function_exceptions"].items()}
    stricter: dict[str, int] = {k: int(v["cap"]) for k, v in budgets["stricter_file_caps"].items()}
    for rel, cap in stricter.items():
        if cap >= max_file or rel in file_exceptions:
            print(f"{rel}: a stricter cap must be below {max_file} and not also an exception")
            return 1
    errors: list[str] = []
    seen_files: set[str] = set()
    seen_funcs: set[str] = set()
    for path in sorted(CORE.rglob("*.gd")):
        rel = path.relative_to(ROOT).as_posix()
        total, functions = measure(path)
        cap = stricter.get(rel, max_file)
        if rel in stricter:
            seen_files.add(rel)
        if rel in file_exceptions:
            seen_files.add(rel)
            cap = file_exceptions[rel]
            if total <= max_file:
                errors.append(f"{rel}: {total} lines is within {max_file}; remove its file exception")
        if total > cap:
            errors.append(f"{rel}: {total} lines > cap {cap}")
        for name, length in functions.items():
            key = f"{rel}::{name}"
            func_cap = max_func
            if key in func_exceptions:
                seen_funcs.add(key)
                func_cap = func_exceptions[key]
                if length <= max_func:
                    errors.append(f"{key}: {length} lines is within {max_func}; remove its function exception")
            if length > func_cap:
                errors.append(f"{key}: {length} lines > cap {func_cap}")
    for rel in sorted((set(file_exceptions) | set(stricter)) - seen_files):
        errors.append(f"{rel}: file cap names a file that does not exist")
    for key in sorted(set(func_exceptions) - seen_funcs):
        errors.append(f"{key}: function exception names a function that does not exist")
    for error in errors:
        print(error)
    if errors:
        print(f"check_core_budgets: {len(errors)} violation(s)")
        return 1
    print(f"check_core_budgets: OK (files <= {max_file} lines, functions <= {max_func} code lines, "
          f"{len(stricter)} stricter file cap(s), {len(file_exceptions)} file and {len(func_exceptions)} function exception(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
