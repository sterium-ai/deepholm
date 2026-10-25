"""B1 review evidence: validate saves written by B1-schema-saves.gd against
game-state.schema.json (JSON Schema 2020-12; needs `pip install jsonschema`).
Usage: python B1-schema-check.py <schema> <save.json>..."""
import json, sys
from jsonschema import Draft202012Validator

schema_path, *saves = sys.argv[1:]
schema = json.load(open(schema_path, encoding='utf-8'))
validator = Draft202012Validator(schema)
failed = False
for path in saves:
    state = json.load(open(path, encoding='utf-8'))
    errors = sorted(validator.iter_errors(state), key=lambda e: list(e.path))
    print(f"{path.replace('\', '/').split('/')[-1]}: {'OK' if not errors else str(len(errors)) + ' error(s)'}")
    for error in errors[:10]:
        failed = True
        print("   ", list(error.path), error.message[:200])
sys.exit(1 if failed else 0)
