# Sigma → Sigma cross-org workbook port

Copy a Sigma workbook from one Sigma org into another **when both orgs already
read the same warehouse tables** (same paths, same column names) — for example
moving a demo, template, or sample-data workbook out of a shared org into a
personal or customer org.

A workbook spec is ~95% org-agnostic, so porting is not a rebuild: it is a
**reference-remapping** job over a spec you copy verbatim, plus a short list of
things that genuinely cannot cross an org boundary. The hard part is that the
failures are asymmetric — some are loud `400`s on create, and some are silent (a
`2xx` create whose elements render empty, or an image that collapses to a strip).
So the skill is **audit-first and verify-hard-after**.

This is **not** a BI-tool converter (that is [sigma-migration-skills](https://github.com/twells89/sigma-migration-skills)
territory) and **not** a data migration — the target must already have the tables.

## What's here

```
skills/sigma-cross-org-port/
  SKILL.md                     # the workflow: 7 phases, audit → recover → port → verify
  refs/non-portable-surface.md # what is org-scoped, what is opaque (do not "fix"), what has no automated path
  refs/spec-asymmetries.md     # why a readback is not a create body; the error → cause catalog
  scripts/port_workbook.py     # audit + remap connections/dataModels/images/columns, emit a create body
  scripts/port_data_model.py   # port a data model a workbook depends on (source.kind: data-model)
  scripts/recover_images.py    # recover org-scoped image uploads via a PDF export
  scripts/verify_port.py       # structure diff + live compile probe + source baseline
  fixtures/                    # synthetic spec for the offline smoke test
tools/test-port-smoke.sh       # offline, creds-free pipeline check (also run in CI)
```

## Endpoint surface

Uses the current workbook **contents** endpoints (JSON only):

| Step | Endpoint |
|---|---|
| Read source | `GET /v2/workbooks/{id}?includeContents=true` — doc under `.contents` |
| Validate | `POST /v2/workbooks` with `dryRun: true` |
| Create | `POST /v2/workbooks` with `{name, folderId, contents}` |
| Update | `PUT /v2/workbooks/{id}/contents` with `{contents}` |

The legacy `/v2/workbooks/spec*` family still works; the scripts read either
envelope but write the `contents` one.

## Prerequisites

- API credentials for **both** orgs, and the right base URL for each cloud/region
  (they frequently differ). A token is obtained via Sigma's OAuth client-credentials
  flow; the scripts read `$SIGMA_API_TOKEN` or take `--token`.
- `python3` with `pyyaml`. `poppler` (`pdfimages`) only if the workbook has image
  uploads; `pillow` only if those images need downscaling.

## Quick start

```bash
# 1. read the source workbook
curl -s -H "Authorization: Bearer $SRC_TOKEN" \
  "$SRC_BASE/v2/workbooks/<SRC_WB_ID>?includeContents=true" > src.json

# 2. audit — lists every org-scoped ref that needs a decision, exits non-zero until clean
python3 skills/sigma-cross-org-port/scripts/port_workbook.py \
  --src-spec src.json --out /dev/null --report audit.json --audit-only

# 3. port — supply the mappings the audit named
python3 skills/sigma-cross-org-port/scripts/port_workbook.py \
  --src-spec src.json --out dst.json --report port.json \
  --folder-id <DST_FOLDER> --name "<Name>" \
  --map-connection <SRC_CONN>=<DST_CONN>

# 4. dry-run then create on the target
jq '. + {dryRun:true}' dst.json | curl -s -X POST -H "Authorization: Bearer $DST_TOKEN" \
  -H "Content-Type: application/json" --data-binary @- "$DST_BASE/v2/workbooks" | jq '{valid, errors}'
curl -s -X POST -H "Authorization: Bearer $DST_TOKEN" -H "Content-Type: application/json" \
  --data-binary @dst.json "$DST_BASE/v2/workbooks" | jq '{workbookId, url}'
```

Read `SKILL.md` before a real port — it covers image recovery, input-table data
(which does not port), lost action logic in readbacks, and the three-gate
verification (structure + compile + render), because a `2xx` on create proves nothing.

## License

MIT © 2026 Thomas Wells
