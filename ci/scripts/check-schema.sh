#!/usr/bin/env bash
# Kiểm mọi registry/apps/*/service.yaml theo registry/schema/service.schema.json.
# Sai một trường ở đây là ApplicationSet sinh ra Application sai tên hoặc không
# sinh gì cả — và nó không báo lỗi, chỉ im lặng.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$@" <<'PY'
import glob, json, sys

try:
    import jsonschema
except ImportError:
    sys.exit("thiếu jsonschema: pip install jsonschema")
import yaml

schema = json.load(open("registry/schema/service.schema.json"))
validator = jsonschema.Draft7Validator(schema)

fail = 0
files = sorted(glob.glob("registry/apps/*/service.yaml"))
for f in files:
    doc = yaml.safe_load(open(f))
    for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.path)):
        where = ".".join(str(p) for p in err.path) or "(gốc)"
        print(f"❌ {f}: {where}: {err.message}")
        fail = 1

if not fail:
    print(f"✅ {len(files)} service.yaml đúng schema")
sys.exit(fail)
PY
