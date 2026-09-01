#!/usr/bin/env bash
#
# atlas infra apply -- cluster, dedicated search nodes, database user, access list.
#
# Everything is named `incident-<slug>` and the cluster is tagged, so this
# never adopts or deletes resources it did not create. That matters more here
# than on GCP: an Atlas project is a shared container, and the operator's own
# clusters usually live alongside.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT_ID="${MONGODB_ATLAS_PROJECT_ID:?project not set}"

PROVIDER="${ATLAS_PROVIDER:-GCP}"
REGION="${ATLAS_REGION:-CENTRAL_US}"
TIER="${ATLAS_CLUSTER_TIER:-M10}"
MEMBERS="${ATLAS_CLUSTER_MEMBERS:-3}"
DB_NAME="${DB_NAME:-incidents}"

SEARCH_NODE_SIZE="${ATLAS_SEARCH_NODE_SIZE:-S20_HIGHCPU_NVME}"
SEARCH_NODE_COUNT="${ATLAS_SEARCH_NODE_COUNT:-2}"

CLUSTER_TIMEOUT="${ATLAS_CLUSTER_TIMEOUT:-1800}"
SEARCH_TIMEOUT="${ATLAS_SEARCH_TIMEOUT:-1800}"

echo "project: ${PROJECT_ID}"
echo

# --- resolve the instance ---------------------------------------------------
cluster=""
slug="${ATLAS_INSTANCE_SLUG:-}"
origin=""

if [[ -n "$slug" ]]; then
  cluster="incident-${slug}"
  origin="ATLAS_INSTANCE_SLUG"
elif cluster="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_CLUSTER_NAME 2>/dev/null)"; then
  slug="${cluster##*-}"
  origin="${HOST_OUTPUT_DIR}/atlas.env"
else
  owned="$(atlas clusters list -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for c in d.get("results", d if isinstance(d, list) else []):
    tags = {t.get("key"): t.get("value") for t in (c.get("tags") or [])}
    if tags.get("managed-by") == "incident-automation":
        print(c.get("name"))
' || true)"
  case "$(wc -l <<<"${owned:-}" | tr -d ' ')" in
    0|"") : ;;
    1)
      if [[ -n "$owned" ]]; then
        cluster="$owned"
        slug="${cluster##*-}"
        origin="discovered by tag"
      fi
      ;;
    *)
      echo "$owned" >&2
      die "more than one tagged cluster in this project; set ATLAS_INSTANCE_SLUG to pick one"
      ;;
  esac
fi

if [[ -z "$cluster" ]]; then
  slug="$(generate_slug)" || die "could not generate an instance slug"
  cluster="incident-${slug}"
  origin="generated"
fi

echo "instance"
echo "  slug:    ${slug} (${origin})"
echo "  cluster: ${cluster}"
echo "  target:  ${TIER} on ${PROVIDER} ${REGION}, ${MEMBERS} members"
echo

# --- cluster ----------------------------------------------------------------
echo "cluster"
if atlas clusters describe "$cluster" -o json >/dev/null 2>&1; then
  echo "  ${cluster} (exists)"
else
  if ! err="$(atlas clusters create "$cluster" \
      --provider "$PROVIDER" \
      --region "$REGION" \
      --tier "$TIER" \
      --members "$MEMBERS" \
      --tag "managed-by=incident-automation" \
      --tag "instance=${slug}" 2>&1 >/dev/null)"; then
    echo "$err" >&2
    # Capacity is a real failure the operator must act on, not something to
    # retry through. Say which combination failed so the fix is obvious.
    if atlas_is_capacity_error "$err"; then
      die "${PROVIDER} ${REGION} cannot take a ${TIER} right now -- try another region via ATLAS_REGION, or another provider via ATLAS_PROVIDER"
    fi
    die "could not create cluster ${cluster}"
  fi
  echo "  ${cluster} (creating)"
fi

atlas_wait_for_state "cluster" "$CLUSTER_TIMEOUT" IDLE \
  bash -c "atlas clusters describe '$cluster' -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"stateName\",\"\"))'" \
  || die "cluster ${cluster} did not become IDLE"
echo "  ready"
echo

# --- search nodes -----------------------------------------------------------
# Dedicated nodes, not search on the cluster nodes -- the demo is partly about
# showing that separation.
echo "search nodes"
if existing="$(atlas clusters search nodes list --clusterName "$cluster" -o json 2>/dev/null)" \
   && python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("specs") else 1)' <<<"$existing" 2>/dev/null; then
  echo "  already deployed"
else
  spec="$(mktemp /tmp/search-nodes.XXXXXX.json)"
  cat > "$spec" <<JSON
{
  "specs": [
    { "instanceSize": "${SEARCH_NODE_SIZE}", "nodeCount": ${SEARCH_NODE_COUNT} }
  ]
}
JSON
  if ! err="$(atlas clusters search nodes create --clusterName "$cluster" --file "$spec" 2>&1 >/dev/null)"; then
    rm -f "$spec"
    echo "$err" >&2
    if atlas_is_capacity_error "$err"; then
      die "no capacity for ${SEARCH_NODE_SIZE} search nodes in ${PROVIDER} ${REGION} -- try ATLAS_SEARCH_NODE_SIZE"
    fi
    die "could not create search nodes"
  fi
  rm -f "$spec"
  echo "  ${SEARCH_NODE_COUNT} x ${SEARCH_NODE_SIZE} (creating)"

  atlas_wait_for_state "search nodes" "$SEARCH_TIMEOUT" IDLE \
    bash -c "atlas clusters search nodes list --clusterName '$cluster' -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"stateName\",\"\"))'" \
    || die "search nodes did not become IDLE"
  echo "  ready"
fi
echo

# --- database user ----------------------------------------------------------
echo "database user"
db_user="incident-${slug}"
db_password="$(read_env_value "$ATLAS_ENV_FILE" ATLAS_DB_PASSWORD 2>/dev/null || true)"

if atlas dbusers describe "$db_user" -o json >/dev/null 2>&1 && [[ -n "$db_password" ]]; then
  echo "  ${db_user} (exists)"
else
  # A user with no recorded password is unusable, so replace it rather than
  # leaving a credential nobody holds.
  if atlas dbusers describe "$db_user" -o json >/dev/null 2>&1; then
    run_quiet atlas dbusers delete "$db_user" --force || true
    echo "  ${db_user} (recreating, password not recorded)"
  fi
  db_password="$(generate_password)" || die "could not generate a password"
  run_quiet atlas dbusers create readWriteAnyDatabase \
    --username "$db_user" \
    --password "$db_password" \
    || die "could not create database user ${db_user}"
  echo "  ${db_user} (created)"
fi
echo

# --- access list ------------------------------------------------------------
echo "access list"
if atlas accessLists describe "0.0.0.0/0" -o json >/dev/null 2>&1; then
  echo "  0.0.0.0/0 (exists)"
else
  run_quiet atlas accessLists create "0.0.0.0/0" \
    --type cidrBlock \
    --comment "incident-automation ${slug}" \
    || die "could not add 0.0.0.0/0 to the access list"
  echo "  0.0.0.0/0 (added)"
fi
echo

# --- record -----------------------------------------------------------------
srv="$(atlas clusters connectionStrings describe "$cluster" -o json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("standardSrv",""))')"
[[ -n "$srv" ]] || die "could not read the connection string for ${cluster}"

host="${srv#mongodb+srv://}"
uri="mongodb+srv://${db_user}:${db_password}@${host}/?retryWrites=true&w=majority"

umask 077
cat > "$ATLAS_ENV_FILE" <<EOF
# Written by \`atlas infra apply\`. Consumed by the demo apps.
ATLAS_PROJECT_ID=${PROJECT_ID}
ATLAS_INSTANCE_SLUG=${slug}
ATLAS_CLUSTER_NAME=${cluster}
ATLAS_DB_USER=${db_user}
ATLAS_DB_PASSWORD=${db_password}
DB_NAME=${DB_NAME}
MONGODB_URI=${uri}
EOF

cat <<EOF
done

  cluster   ${cluster}  (${TIER}, ${PROVIDER} ${REGION})
  search    ${SEARCH_NODE_COUNT} x ${SEARCH_NODE_SIZE}
  db user   ${db_user}
  record    ${HOST_OUTPUT_DIR}/atlas.env
EOF
