#!/usr/bin/env python3
"""Rewrite a Sigma DATA MODEL spec so it can be created in a DIFFERENT org.

A workbook that sources a data model (element source.kind: data-model) reaches the
warehouse THROUGH the model, not directly — so a cross-org port of such a workbook
is two steps: port the model first with this script, create it, then port the
workbook with `port_workbook.py --map-datamodel <old>=<new>`.

Input  : a data model as returned by GET /v2/dataModels/{id}/spec. Unlike a
         workbook, the doc is FLAT — schemaVersion/kind/pages live at the top
         level, not under a `document`/`contents` wrapper. A wrapped body is
         tolerated on read.
Output : a create body {name, folderId, description?, <doc...>} for
         POST /v2/dataModels/spec, plus a JSON report. JSON out.

Run with no --map-connection first (audit mode): the report lists every
connectionId that needs a target, and the tool exits non-zero while any remain.
Supply the mappings, re-run, then POST.

Element ids inside the model are preserved by a verbatim spec port, so a workbook
that references them by id keeps resolving after the dataModelId is repointed.

Stdlib only (PyYAML for read). No network.
"""

import argparse
import json
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML required: python3 -m pip install pyyaml")

# GET returns these response-only envelope keys alongside the model doc; a create
# body must not carry them (ids/timestamps/users are source-org, folderId is the
# source folder and is overridden by --folder-id).
ENVELOPE = {"createdAt", "createdBy", "dataModelId", "dataModelUrlId",
            "documentVersion", "latestDocumentVersion", "ownerId", "updatedAt",
            "updatedBy", "url", "folderId", "path"}


def walk(node, fn):
    if isinstance(node, dict):
        fn(node)
        for v in list(node.values()):
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)


def load_spec(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def parse_pairs(items, sep="="):
    out = {}
    for raw in items:
        if sep not in raw:
            sys.exit(f"bad mapping {raw!r}: expected LEFT{sep}RIGHT")
        left, right = raw.split(sep, 1)
        out[left.strip()] = right.strip()
    return out


def remap_connections(doc, cmap, counts):
    def visit(d):
        cid = d.get("connectionId")
        if isinstance(cid, str) and cid in cmap:
            d["connectionId"] = cmap[cid]
            counts["connectionId"] += 1
    walk(doc, visit)


def strip_base_grouping(doc, counts):
    def visit(d):
        if d.get("groupingId") == "base":
            del d["groupingId"]
            counts["groupingId_base_stripped"] += 1
    walk(doc, visit)


def collect(doc):
    conns, paths = set(), []
    seen = set()

    def visit(d):
        cid = d.get("connectionId")
        if isinstance(cid, str):
            conns.add(cid)
        if d.get("kind") == "warehouse-table" and isinstance(d.get("path"), list):
            key = tuple(d["path"])
            if key not in seen:
                seen.add(key)
                paths.append(list(key))
    walk(doc, visit)
    return conns, paths


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src-spec", required=True,
                    help="data model from GET /v2/dataModels/{id}/spec (YAML or JSON)")
    ap.add_argument("--out", required=True, help="create body to write (JSON)")
    ap.add_argument("--report", required=True, help="JSON report to write")
    ap.add_argument("--folder-id", help="target folder (required unless --audit-only)")
    ap.add_argument("--name", help="model name (default: source name)")
    ap.add_argument("--map-connection", action="append", default=[],
                    metavar="SRC=DST", help="repeatable")
    ap.add_argument("--audit-only", action="store_true",
                    help="report what needs mapping; write no create body")
    args = ap.parse_args()

    src = load_spec(args.src_spec)
    # doc is flat; tolerate a wrapper if one is ever present.
    doc = src.get("document") or src.get("contents") or src
    if not isinstance(doc, dict) or "pages" not in doc:
        sys.exit("spec has no 'pages' — is this a data model spec?")

    cmap = parse_pairs(args.map_connection)
    counts = dict(connectionId=0, groupingId_base_stripped=0)

    remap_connections(doc, cmap, counts)
    strip_base_grouping(doc, counts)

    conns, paths = collect(doc)
    target_conns = set(cmap.values())
    unmapped = sorted(c for c in conns if c not in target_conns)

    report = {
        "source": {"dataModelId": src.get("dataModelId"), "name": src.get("name")},
        "rewrites": counts,
        "connection_map": cmap,
        "blockers": {"unmapped_connectionIds": unmapped},
        "warehouse_paths": paths,   # verify each exists on the target connection
    }

    if not args.audit_only and not unmapped:
        if not args.folder_id:
            sys.exit("--folder-id is required to write a create body")
        body = {k: v for k, v in doc.items() if k not in ENVELOPE}
        body["name"] = args.name or src.get("name") or doc.get("name")
        body["folderId"] = args.folder_id
        if src.get("description"):
            body["description"] = src["description"]
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(body, fh, indent=2)
        report["wrote"] = args.out

    with open(args.report, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))

    if unmapped:
        print("\nUNRESOLVED connectionIds — supply --map-connection and re-run.",
              file=sys.stderr)
        return 2
    if args.audit_only:
        print("\nAudit clean. Re-run without --audit-only to write the create body.",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
