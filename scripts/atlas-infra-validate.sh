#!/usr/bin/env bash
#
# atlas infra validate -- prove the provisioned infrastructure works.
#
# Everything else reports that API calls returned success. This connects with
# the MONGODB_URI in atlas.env, as the database user that was created, which
# is the artifact the demo apps actually consume. A wrong password, a missing
# access list entry or a cluster that never finished surfaces here rather than
# in the app.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT_ID="${MONGODB_ATLAS_PROJECT_ID:?project not set}"

failures=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; failures=$((failures + 1)); }

echo "project: ${PROJECT_ID}"
echo

[[ -f "$ATLAS_ENV_FILE" ]] \
  || die "no ${HOST_OUTPUT_DIR}/atlas.env -- run \`atlas infra apply\` first"

cluster="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_CLUSTER_NAME 2>/dev/null || true)"
db_user="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_DB_USER 2>/dev/null || true)"
spi="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_SPI_NAME 2>/dev/null || true)"
uri="$(read_env_value "$ATLAS_ENV_FILE" MONGODB_URI 2>/dev/null || true)"
conns="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_STREAM_CONNECTIONS 2>/dev/null || echo "incident-events fix-events")"

echo "target"
echo "  cluster: ${cluster:-<none>}"
echo "  stream:  ${spi:-<none>}"
echo "  user:    ${db_user:-<none>}"
echo

# --- cluster ----------------------------------------------------------------
echo "cluster"
if info="$(atlas clusters describe "$cluster" -o json 2>/dev/null)"; then
  state="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("stateName",""))' "$info")"
  owner="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print({t.get("key"): t.get("value") for t in (d.get("tags") or [])}.get("managed-by", ""))
' "$info")"
  [[ "$state" == "IDLE" ]] && ok "IDLE" || bad "state is ${state:-unknown}"
  [[ "$owner" == "incident-automation" ]] && ok "tagged managed-by=incident-automation" \
    || bad "not tagged as ours"
else
  bad "${cluster} not found"
fi

if nodes="$(atlas clusters search nodes list --clusterName "$cluster" -o json 2>/dev/null)"; then
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
specs = d.get("specs", [])
raise SystemExit(0 if specs and d.get("stateName") == "IDLE" else 1)
' "$nodes" 2>/dev/null \
    && ok "search nodes IDLE" \
    || bad "search nodes not IDLE"
else
  bad "no search nodes on ${cluster}"
fi
echo

# --- access ------------------------------------------------------------------
echo "access"
if atlas dbusers describe "$db_user" -o json >/dev/null 2>&1; then
  ok "database user ${db_user} exists"
else
  bad "database user ${db_user} not found"
fi

if atlas accessLists describe "0.0.0.0/0" -o json >/dev/null 2>&1; then
  ok "0.0.0.0/0 on the access list"
else
  bad "0.0.0.0/0 missing from the access list"
fi
echo

# --- stream processing ------------------------------------------------------
echo "stream processing"
if atlas api streams getStreamInstance --groupId "$PROJECT_ID" --tenantName "$spi" >/dev/null 2>&1; then
  ok "instance ${spi} exists"
  for conn in $conns; do
    if atlas streams connections describe "$conn" --instance "$spi" -o json >/dev/null 2>&1; then
      ok "connection ${conn}"
    else
      bad "connection ${conn} missing"
    fi
  done
else
  bad "instance ${spi} not found"
fi
echo

# --- the connection string the apps use -------------------------------------
# The only check here that exercises the data plane. Everything above asks the
# control plane whether it thinks the resource exists.
echo "connection"
if [[ -z "$uri" ]]; then
  bad "no MONGODB_URI in atlas.env"
else
  ok "MONGODB_URI recorded"
  if out="$(mongosh "$uri" --quiet --eval 'db.adminCommand({ ping: 1 }).ok' 2>&1)"; then
    if [[ "$(tr -d '[:space:]' <<<"$out")" == "1" ]]; then
      ok "connects and authenticates as ${db_user}"
    else
      bad "connected but ping returned: ${out}"
    fi
  else
    echo "${out}" | tail -3 | sed 's/^/        /'
    bad "cannot connect with the recorded URI"
  fi
fi
echo

if [[ $failures -eq 0 ]]; then
  echo "valid -- the apps can connect and the stream instance is ready"
else
  echo "${failures} check(s) failed"
  exit 1
fi
