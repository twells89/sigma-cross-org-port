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
assert b["unmapped_dataModelIds"] == ["dm-src-00000000"], b
print("   OK: audit flagged conn, image, and dataModel", b["unmapped_dataModelIds"])
PY

echo "2. with mappings, porter emits a valid JSON create body keyed contents"
printf 'upload-abc123\t%s\n' "$skill/fixtures/logo.png" > "$work/images.tsv"
python3 "$skill/scripts/port_workbook.py" --src-spec "$fix" \
  --out "$work/dst.json" --report "$work/port.json" \
  --folder-id "ffffffff-ffff-ffff-ffff-ffffffffffff" --name "Ported" \
  --map-connection 11111111-1111-1111-1111-111111111111=22222222-2222-2222-2222-222222222222 \
  --map-datamodel dm-src-00000000=dm-dst-99999999 \
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
dm = doc["elements"][2]["source"]
assert dm["dataModelId"] == "dm-dst-99999999", dm
print("   OK: contents body, conn+dataModel remapped, groupingId stripped, image inlined")
PY
echo "3. port_data_model: audit flags the unmapped connection; body is flat + remapped"
dmfix="$skill/fixtures/sample-data-model.json"
set +e
python3 "$skill/scripts/port_data_model.py" --src-spec "$dmfix" \
  --out /dev/null --report "$work/dm-audit.json" --audit-only >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: dm audit exited 0 with an unmapped connection"; exit 1; }
python3 - "$work/dm-audit.json" <<'PY2'
import json, sys
b = json.load(open(sys.argv[1]))["blockers"]
assert b["unmapped_connectionIds"] == ["11111111-1111-1111-1111-111111111111"], b
print("   OK: dm audit flagged", b["unmapped_connectionIds"])
PY2
python3 "$skill/scripts/port_data_model.py" --src-spec "$dmfix" \
  --out "$work/dm.json" --report "$work/dm-port.json" \
  --folder-id "ffffffff-ffff-ffff-ffff-ffffffffffff" --name "Ported Model" \
  --map-connection 11111111-1111-1111-1111-111111111111=22222222-2222-2222-2222-222222222222 \
  >/dev/null 2>&1
python3 - "$work/dm.json" <<'PY2'
import json, sys
body = json.load(open(sys.argv[1]))
assert set(body) >= {"name", "folderId", "pages", "schemaVersion"}, body.keys()
for k in ("dataModelId", "ownerId", "url", "documentVersion"):
    assert k not in body, f"envelope key {k} leaked into create body"
tbl = body["pages"][0]["elements"][0]
assert tbl["connectionId"] == "22222222-2222-2222-2222-222222222222", tbl
assert "groupingId" not in tbl, "groupingId: base must be stripped"
print("   OK: flat create body, envelope stripped, connection remapped, groupingId stripped")
PY2
echo "SMOKE OK"
