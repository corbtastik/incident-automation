#!/usr/bin/env bash
#
# atlas infra apply -- cluster, dedicated search nodes, database user, access
# list, stream processing instance and its connections.
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

SPI_PROVIDER="${ATLAS_SPI_PROVIDER:-$PROVIDER}"
SPI_REGION="${ATLAS_SPI_REGION:-US_CENTRAL1}"
SPI_TIER="${ATLAS_SPI_TIER:-SP30}"

# The pipelines reference these connection names in their $source stages, so
# they are fixed, not configurable.
STREAM_CONNECTIONS=(incident-events fix-events)

SEARCH_NODE_SIZE="${ATLAS_SEARCH_NODE_SIZE:-S20_HIGHCPU_NVME}"
SEARCH_NODE_COUNT="${ATLAS_SEARCH_NODE_COUNT:-2}"

CLUSTER_TIMEOUT="${ATLAS_CLUSTER_TIMEOUT:-1800}"
SEARCH_TIMEOUT="${ATLAS_SEARCH_TIMEOUT:-1800}"

assume_yes=0
dry_run=0
interactive=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)      assume_yes=1 ;;
    --dry-run)     dry_run=1 ;;
    --interactive) interactive=1 ;;
  esac
done

# Whether the operator set these themselves. If they did, neither the
# interactive prompts nor the region mapping may override them.
spi_region_explicit=0
spi_provider_explicit=0
[[ -n "${ATLAS_SPI_REGION:-}" ]]   && spi_region_explicit=1
[[ -n "${ATLAS_SPI_PROVIDER:-}" ]] && spi_provider_explicit=1

echo "project: ${PROJECT_ID}"
echo

# --- interactive selection --------------------------------------------------
# Tier is asked before region on purpose: availableRegions filters by both, so
# asking in this order means the region list reflects what is actually
# available at that tier -- which is where capacity failures come from.
if [[ $interactive -eq 1 ]]; then
  [[ -t 0 ]] || die "--interactive needs a terminal -- add -it to podman run"

  prompt_choice PROVIDER "cloud provider" "$PROVIDER" GCP AWS AZURE
  prompt_choice TIER "cluster tier" "$TIER" M10 M20 M30 M40

  mapfile -t region_opts < <(atlas_regions_for "$PROVIDER" "$TIER")
  if [[ ${#region_opts[@]} -eq 0 ]]; then
    die "no regions returned for ${PROVIDER} at ${TIER}"
  fi
  # Prefer the configured region when Atlas offers it, so the default stays
  # the one that is mapped and tested rather than whichever Atlas happens to
  # list first.
  region_default="${region_opts[0]}"
  for candidate in "${region_opts[@]}"; do
    [[ "$candidate" == "$REGION" ]] && { region_default="$REGION"; break; }
  done
  prompt_choice REGION "region for ${PROVIDER} ${TIER}" "$region_default" "${region_opts[@]}"

  prompt_choice SEARCH_NODE_SIZE "search node tier" "$SEARCH_NODE_SIZE" \
    S20_HIGHCPU_NVME S30_HIGHCPU_NVME S40_HIGHCPU_NVME
  prompt_choice SPI_TIER "stream processing tier" "$SPI_TIER" SP10 SP30 SP50
  echo
fi

# The stream instance follows the cluster's provider unless told otherwise.
# Recomputed here because the interactive prompts may have changed PROVIDER
# after the defaults were resolved.
[[ $spi_provider_explicit -eq 0 ]] && SPI_PROVIDER="$PROVIDER"

# Stream regions use different names from cluster regions for the same place.
# Derive rather than prompt: it is a naming inconsistency, not a decision the
# operator should have to make.
if [[ $spi_region_explicit -eq 0 ]]; then
  mapped="$(atlas_spi_region_for "$SPI_PROVIDER" "$REGION")"
  if [[ -n "$mapped" ]]; then
    SPI_REGION="$mapped"
  else
    echo "warning: no stream region mapped for ${SPI_PROVIDER} ${REGION};" >&2
    echo "         using ${SPI_REGION}. Set ATLAS_SPI_REGION to override." >&2
    echo >&2
  fi
fi

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
echo "  search:  ${SEARCH_NODE_COUNT} x ${SEARCH_NODE_SIZE}"
echo "  stream:  ${SPI_TIER} on ${SPI_PROVIDER} ${SPI_REGION}"
echo

# --- plan -------------------------------------------------------------------
# Provisioning takes 20-25 minutes and bills continuously, so say what will
# happen before doing any of it. Re-runs are common here, and most of the time
# the honest answer is "almost nothing".
plan_create=()
plan_exists=()

if atlas clusters describe "$cluster" -o json >/dev/null 2>&1; then
  plan_exists+=("cluster        ${cluster}")
  if atlas clusters search nodes list --clusterName "$cluster" -o json 2>/dev/null \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("specs") else 1)' 2>/dev/null; then
    plan_exists+=("search nodes   deployed")
  else
    plan_create+=("search nodes   ${SEARCH_NODE_COUNT} x ${SEARCH_NODE_SIZE}")
  fi
else
  plan_create+=("cluster        ${cluster}  (${TIER}, ${PROVIDER} ${REGION}, ${MEMBERS} members)")
  plan_create+=("search nodes   ${SEARCH_NODE_COUNT} x ${SEARCH_NODE_SIZE}")
fi

planned_user="incident-${slug}"
if atlas dbusers describe "$planned_user" -o json >/dev/null 2>&1 \
   && [[ -n "$(read_env_value "$ATLAS_ENV_FILE" ATLAS_DB_PASSWORD 2>/dev/null || true)" ]]; then
  plan_exists+=("database user  ${planned_user}")
else
  plan_create+=("database user  ${planned_user}")
fi

if atlas accessLists describe "0.0.0.0/0" -o json >/dev/null 2>&1; then
  plan_exists+=("access list    0.0.0.0/0")
else
  plan_create+=("access list    0.0.0.0/0")
fi

planned_spi="incident-${slug}-spi"
if atlas api streams getStreamInstance --groupId "$PROJECT_ID" --tenantName "$planned_spi" >/dev/null 2>&1; then
  plan_exists+=("stream         ${planned_spi}")
  for conn in "${STREAM_CONNECTIONS[@]}"; do
    if atlas streams connections describe "$conn" --instance "$planned_spi" -o json >/dev/null 2>&1; then
      plan_exists+=("connection     ${conn}")
    else
      plan_create+=("connection     ${conn}")
    fi
  done
else
  plan_create+=("stream         ${planned_spi}  (${SPI_TIER}, ${SPI_PROVIDER} ${SPI_REGION})")
  for conn in "${STREAM_CONNECTIONS[@]}"; do
    plan_create+=("connection     ${conn}")
  done
fi

echo "plan"
if [[ ${#plan_create[@]} -eq 0 ]]; then
  echo "  nothing to create -- everything is already provisioned"
else
  printf '  create  %s\n' "${plan_create[@]}"
fi
[[ ${#plan_exists[@]} -gt 0 ]] && printf '  exists  %s\n' "${plan_exists[@]}"
echo

if [[ $dry_run -eq 1 ]]; then
  echo "dry run -- nothing was created"
  exit 0
fi

# Creating is the intended action, so a non-interactive run proceeds rather
# than refusing. destroy is the opposite, and refuses without --yes.
if [[ ${#plan_create[@]} -gt 0 && $assume_yes -eq 0 && -t 0 ]]; then
  read -r -p "proceed? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 0; }
  echo
fi

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

# --- stream processing ------------------------------------------------------
# Stream instances carry no tags, so the name is the ownership marker and
# destroy matches on it. That is what keeps an operator's own instance safe.
spi="incident-${slug}-spi"

echo "stream processing"
if atlas api streams getStreamInstance --groupId "$PROJECT_ID" --tenantName "$spi" >/dev/null 2>&1; then
  echo "  ${spi} (exists)"
else
  # The CLI's own `streams instances create` only offers AWS and AZURE, so
  # the passthrough is used to keep the instance on the same cloud as the
  # cluster. Note the region naming differs between the two: a cluster in
  # CENTRAL_US pairs with an instance in US_CENTRAL1.
  spi_spec="$(mktemp /tmp/spi.XXXXXX.json)"
  cat > "$spi_spec" <<JSON
{
  "name": "${spi}",
  "dataProcessRegion": { "cloudProvider": "${SPI_PROVIDER}", "region": "${SPI_REGION}" },
  "streamConfig": { "tier": "${SPI_TIER}" }
}
JSON
  if ! err="$(atlas api streams createStreamInstance --groupId "$PROJECT_ID" --file "$spi_spec" 2>&1 >/dev/null)"; then
    rm -f "$spi_spec"
    echo "$err" >&2
    if atlas_is_capacity_error "$err"; then
      die "no capacity for a ${SPI_TIER} instance in ${SPI_PROVIDER} ${SPI_REGION} -- try ATLAS_SPI_REGION or ATLAS_SPI_TIER"
    fi
    die "could not create stream instance ${spi}"
  fi
  rm -f "$spi_spec"
  echo "  ${spi} (created, ${SPI_TIER} on ${SPI_PROVIDER} ${SPI_REGION})"

  # No documented state field on the instance, so readiness is "the API can
  # retrieve it" rather than a named state.
  waited=0
  until atlas api streams getStreamInstance --groupId "$PROJECT_ID" --tenantName "$spi" >/dev/null 2>&1; do
    [[ $waited -ge 300 ]] && die "stream instance ${spi} did not become retrievable"
    sleep 10
    waited=$((waited + 10))
    echo "  waiting for ${spi} (${waited}s)"
  done
fi

for conn in "${STREAM_CONNECTIONS[@]}"; do
  if atlas streams connections describe "$conn" --instance "$spi" -o json >/dev/null 2>&1; then
    echo "  connection ${conn} (exists)"
  else
    conn_spec="$(mktemp /tmp/conn.XXXXXX.json)"
    cat > "$conn_spec" <<JSON
{
  "name": "${conn}",
  "type": "Cluster",
  "clusterName": "${cluster}",
  "dbRoleToExecute": { "role": "atlasAdmin", "type": "BUILT_IN" }
}
JSON
    if ! err="$(atlas streams connections create "$conn" --instance "$spi" --file "$conn_spec" 2>&1 >/dev/null)"; then
      rm -f "$conn_spec"
      echo "$err" >&2
      die "could not create stream connection ${conn}"
    fi
    rm -f "$conn_spec"
    echo "  connection ${conn} (created)"
  fi
done
echo

# The stream instance exposes a hostname the simulator connects to with
# mongosh to create its processors. Recorded here so the app never needs Atlas
# API credentials of its own.
spi_host="$(atlas streams instances describe "$spi" -o json 2>/dev/null \
  | python3 -c 'import json,sys; h=json.load(sys.stdin).get("hostnames") or [""]; print(h[0])' 2>/dev/null || true)"

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
ATLAS_PROVIDER=${PROVIDER}
ATLAS_REGION=${REGION}
ATLAS_CLUSTER_TIER=${TIER}
ATLAS_SEARCH_NODE_SIZE=${SEARCH_NODE_SIZE}
ATLAS_SPI_TIER=${SPI_TIER}
ATLAS_SPI_REGION=${SPI_REGION}
ATLAS_DB_USER=${db_user}
ATLAS_DB_PASSWORD=${db_password}
ATLAS_SPI_NAME=${spi}
ATLAS_SPI_HOST=${spi_host}
ATLAS_SPI_URI=mongodb://${db_user}:${db_password}@${spi_host}/?authSource=admin&tls=true
ATLAS_STREAM_CONNECTIONS=${STREAM_CONNECTIONS[*]}
DB_NAME=${DB_NAME}
MONGODB_URI=${uri}
EOF

cat <<EOF
done

  cluster   ${cluster}  (${TIER}, ${PROVIDER} ${REGION})
  search    ${SEARCH_NODE_COUNT} x ${SEARCH_NODE_SIZE}
  db user   ${db_user}
  stream    ${spi}  (${SPI_TIER}, ${SPI_PROVIDER} ${SPI_REGION})
  spi host  ${spi_host:-<unavailable>}
  conns     ${STREAM_CONNECTIONS[*]}
  record    ${HOST_OUTPUT_DIR}/atlas.env
EOF
