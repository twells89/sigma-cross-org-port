#!/usr/bin/env bash
# Offline, creds-free smoke test of the port pipeline.
#
# Proves, without touching any org:
#   1. audit-only FLAGS the org-scoped refs a real port must resolve
#      (an unmapped connectionId and an unmapped image upload) and exits non-zero.
#   2. with those mappings supplied, the porter emits a VALID JSON create body
#      keyed `contents` (the current endpoint shape), strips `groupingId: base`,
#      and remaps the connectionId.
#
# This is a fail-first gate: if port_workbook stopped detecting the blockers, or
# regressed the `contents` envelope, this test fails.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
skill="$here/skills/sigma-cross-org-port"
fix="$skill/fixtures/sample-workbook.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "1. audit-only must flag the unmapped connection + image and exit non-zero"
set +e
python3 "$skill/scripts/port_workbook.py" --src-spec "$fix" \
  --out /dev/null --report "$work/audit.json" --audit-only >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: audit exited 0 with blockers present"; exit 1; }
python3 - "$work/audit.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["blockers"]
assert b["unmapped_connectionIds"] == ["11111111-1111-1111-1111-111111111111"], b
assert b["unmapped_image_uploads"] == ["upload-abc123"], b
print("   OK: audit flagged", b["unmapped_connectionIds"], "and", b["unmapped_image_uploads"])
PY

echo "2. with mappings, porter emits a valid JSON create body keyed contents"
printf 'upload-abc123\t%s\n' "$skill/fixtures/logo.png" > "$work/images.tsv"
python3 "$skill/scripts/port_workbook.py" --src-spec "$fix" \
  --out "$work/dst.json" --report "$work/port.json" \
  --folder-id "ffffffff-ffff-ffff-ffff-ffffffffffff" --name "Ported" \
  --map-connection 11111111-1111-1111-1111-111111111111=22222222-2222-2222-2222-222222222222 \
  --image-map "$work/images.tsv" \
  >/dev/null 2>&1
python3 - "$work/dst.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))                    # must be valid JSON
assert set(body) >= {"name", "folderId", "contents"}, body.keys()
assert "document" not in body, "legacy document key must not be emitted"
doc = body["contents"]
src = doc["elements"][0]["source"]
assert src["connectionId"] == "22222222-2222-2222-2222-222222222222", src
assert "groupingId" not in src, "groupingId: base must be stripped"
img = doc["elements"][1]["source"]
assert img["kind"] == "url" and img["url"].startswith("data:image/png;base64,"), img
print("   OK: contents-keyed body, connection remapped, groupingId:base stripped, image inlined")
PY
echo "SMOKE OK"
