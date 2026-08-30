#!/usr/bin/env bash
#
# atlas status -- report only. Creates, modifies and deletes nothing.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT_ID="${MONGODB_ATLAS_PROJECT_ID:?project not set}"

echo "identity"
if project_json="$(atlas projects describe "$PROJECT_ID" -o json 2>/dev/null)"; then
  project_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' <<<"$project_json")"
  org_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("orgId",""))' <<<"$project_json")"
  echo "  project: ${project_name} (${PROJECT_ID})"
  echo "  org:     ${org_id}"
else
  echo "  project: ${PROJECT_ID}"
  echo
  die "cannot reach the project -- check ATLAS_PUBLIC_KEY, ATLAS_PRIVATE_KEY and ATLAS_PROJECT_ID, and that the key is on the project's API access list"
fi
echo

# `atlas api` is the passthrough used for anything without a first-class
# command -- the stream processors in particular. It is marked public preview,
# so status exercises it rather than assuming it works.
echo "admin api passthrough"
if atlas api projects getProject --groupId "$PROJECT_ID" >/dev/null 2>&1; then
  echo "  ok"
else
  echo "  UNAVAILABLE -- stream processor provisioning depends on this"
fi
echo

echo "clusters"
if clusters="$(atlas clusters list -o json 2>/dev/null)"; then
  # %-formatting, not f-strings: this is a single-quoted shell argument, so
  # escaping double quotes inside an f-string is both ugly and invalid.
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
rows = d.get("results", d if isinstance(d, list) else [])
if not rows:
    print("  none")
for c in rows:
    print("  %s  %s  mongo %s" % (c.get("name"), c.get("stateName", ""), c.get("mongoDBVersion", "")))
' "$clusters"
else
  echo "  unreadable"
fi
echo

echo "search nodes"
if nodes="$(atlas clusters search nodes list -o json 2>/dev/null)"; then
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
specs = d.get("specs", [])
if not specs:
    print("  none")
for s in specs:
    print("  %s x%s" % (s.get("instanceSize", ""), s.get("nodeCount", "")))
' "$nodes"
else
  echo "  none"
fi
echo

echo "stream processing"
if instances="$(atlas streams instances list -o json 2>/dev/null)"; then
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
rows = d.get("results", d if isinstance(d, list) else [])
if not rows:
    print("  none")
for i in rows:
    dp = i.get("dataProcessRegion") or {}
    print("  %s  %s %s" % (i.get("name"), dp.get("cloudProvider", ""), dp.get("region", "")))
' "$instances"
else
  echo "  unreadable"
fi
