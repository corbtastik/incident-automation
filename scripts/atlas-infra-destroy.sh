#!/usr/bin/env bash
#
# atlas infra destroy -- remove the stream instance and its connections, the
# cluster, its search nodes, and the database user.
#
# Only touches resources this tool created. An Atlas project is a shared
# container, so the cluster's `managed-by` tag is checked before deletion --
# never "whatever cluster is in this project".
#
# The 0.0.0.0/0 access list entry is left alone: it is project-wide, may
# predate this tool, and other things in the project may depend on it.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT_ID="${MONGODB_ATLAS_PROJECT_ID:?project not set}"

assume_yes=0
dry_run=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  assume_yes=1 ;;
    --dry-run) dry_run=1 ;;
  esac
done

echo "project: ${PROJECT_ID}"
echo

cluster="${ATLAS_INSTANCE_SLUG:+incident-${ATLAS_INSTANCE_SLUG}}"
[[ -n "$cluster" ]] || cluster="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_CLUSTER_NAME 2>/dev/null || true)"

if [[ -z "$cluster" ]]; then
  cluster="$(atlas clusters list -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [c.get("name") for c in d.get("results", d if isinstance(d, list) else [])
         if {t.get("key"): t.get("value") for t in (c.get("tags") or [])}.get("managed-by") == "incident-automation"]
print(names[0] if len(names) == 1 else "")
' || true)"
fi

if [[ -z "$cluster" ]]; then
  echo "cluster"
  echo "  none found"
  echo
  echo "nothing to destroy"
  exit 0
fi

# Refuse anything this tool did not create, even when named in atlas.env.
owner="$(atlas clusters describe "$cluster" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
print({t.get("key"): t.get("value") for t in (d.get("tags") or [])}.get("managed-by", ""))
' || true)"

if [[ "$owner" != "incident-automation" ]]; then
  die "cluster ${cluster} is not tagged managed-by=incident-automation -- refusing to delete a cluster this tool did not create"
fi

slug="${cluster##*-}"
db_user="incident-${slug}"
spi="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_SPI_NAME 2>/dev/null || true)"
[[ -n "$spi" ]] || spi="incident-${slug}-spi"

# Enumerate before deleting. This took 25 minutes to provision, so the
# listing should be specific enough to recognise -- and to notice when it
# names something unexpected.
echo "will delete"
echo "  cluster        ${cluster}  (tagged managed-by=incident-automation)"

nodes_desc=""
if nodes="$(atlas clusters search nodes list --clusterName "$cluster" -o json 2>/dev/null)"; then
  nodes_desc="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
specs = d.get("specs", [])
print(", ".join("%s x %s" % (s.get("nodeCount", "?"), s.get("instanceSize", "?")) for s in specs) or "")
' "$nodes" 2>/dev/null || true)"
fi
echo "  search nodes   ${nodes_desc:-none}"

if atlas dbusers describe "$db_user" -o json >/dev/null 2>&1; then
  echo "  database user  ${db_user}"
else
  echo "  database user  ${db_user} (absent)"
fi
if atlas api streams getStreamInstance --groupId "$PROJECT_ID" --tenantName "$spi" >/dev/null 2>&1; then
  echo "  stream         ${spi} and its connections"
else
  echo "  stream         ${spi} (absent)"
fi
echo "  artifacts      ${HOST_OUTPUT_DIR}/atlas.env"
echo

echo "will keep"
echo "  access list    0.0.0.0/0 -- project-wide, may predate this tool"
untagged="$(atlas clusters list -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [c.get("name") for c in d.get("results", d if isinstance(d, list) else [])
         if {t.get("key"): t.get("value") for t in (c.get("tags") or [])}.get("managed-by") != "incident-automation"]
print(", ".join(names))
' || true)"
[[ -n "$untagged" ]] && echo "  other clusters ${untagged}"

# Stream instances have no tags, so ownership is the incident-<slug>-spi
# name. Anything else in the project is listed here to make it visible that
# it is out of scope.
others="$(atlas streams instances list -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d.get("results", d if isinstance(d, list) else [])
print(", ".join(i.get("name", "") for i in rows if i.get("name") != sys.argv[1]))
' "$spi" || true)"
[[ -n "$others" ]] && echo "  other streams  ${others}"
echo

if [[ $dry_run -eq 1 ]]; then
  echo "dry run -- nothing was deleted"
  exit 0
fi

if [[ $assume_yes -eq 0 ]]; then
  [[ -t 0 ]] || die "refusing to delete without confirmation -- pass --yes, --dry-run to preview, or run with -it"
  read -r -p "delete? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 0; }
  echo
fi

# Stream processing first: the connections reference the cluster, so removing
# them before it avoids leaving connections pointing at something gone.
echo "stream processing"
if atlas api streams getStreamInstance --groupId "$PROJECT_ID" --tenantName "$spi" >/dev/null 2>&1; then
  conns="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_STREAM_CONNECTIONS 2>/dev/null || echo "incident-events fix-events")"
  for conn in $conns; do
    if atlas streams connections describe "$conn" --instance "$spi" -o json >/dev/null 2>&1; then
      run_quiet atlas streams connections delete "$conn" --instance "$spi" --force || true
      echo "  connection ${conn} (deleted)"
    fi
  done
  run_quiet atlas streams instances delete "$spi" --force \
    || die "could not delete stream instance ${spi}"
  echo "  ${spi} (deleted)"
else
  echo "  ${spi} (absent)"
fi
echo

# Search nodes next: deleting the cluster with them attached is slower and
# occasionally leaves them reported as deploying.
echo "search nodes"
if atlas clusters search nodes list --clusterName "$cluster" -o json >/dev/null 2>&1; then
  run_quiet atlas clusters search nodes delete --clusterName "$cluster" --force || true
  echo "  deleted"
else
  echo "  none"
fi
echo

echo "cluster"
run_quiet atlas clusters delete "$cluster" --force || die "could not delete ${cluster}"
echo "  ${cluster} (deleting)"
echo

echo "database user"
if atlas dbusers describe "$db_user" -o json >/dev/null 2>&1; then
  run_quiet atlas dbusers delete "$db_user" --force || die "could not delete ${db_user}"
  echo "  ${db_user} (deleted)"
else
  echo "  ${db_user} (absent)"
fi
echo

# The app env files describe both halves, so they are stale once either one
# is gone.
echo "artifacts"
if [[ -f "$ATLAS_ENV_FILE" ]]; then
  rm -f "$ATLAS_ENV_FILE"
  echo "  atlas.env (removed)"
else
  echo "  atlas.env (absent)"
fi
for f in simulator.env visualizer.env incident-app-storage-key.json; do
  if [[ -f "${OUTPUT_DIR}/${f}" ]]; then
    rm -f "${OUTPUT_DIR}/${f}"
    echo "  ${f} (removed)"
  fi
done

echo
echo "done -- cluster deletion continues in the background"
