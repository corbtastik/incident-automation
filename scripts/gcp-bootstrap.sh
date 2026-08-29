#!/usr/bin/env bash
#
# gcp bootstrap -- create the scoped service account every other verb runs as.
#
# Runs once, under the operator's own identity. Creating a service account and
# granting it project-level roles needs resourcemanager.projectIamAdmin, which
# the bootstrap account deliberately does not have -- so it cannot create
# itself. Everything after this is non-interactive.
#
# Idempotent: an existing account is reused, and an existing live key is kept
# rather than minting a second one.
#
set -euo pipefail

PROJECT="${CLOUDSDK_CORE_PROJECT:?project not set}"
SA_NAME="${BOOTSTRAP_SA_NAME:-incident-automation-bootstrap}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
KEY_FILE="${OUTPUT_DIR}/gcp-bootstrap-key.json"
ENV_FILE="${OUTPUT_DIR}/bootstrap.env"

# Host-side path, so the emitted file is usable outside the container.
HOST_OUTPUT_DIR="${HOST_OUTPUT_DIR:-./output}"

ROLES=(
  roles/storage.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountKeyAdmin
  roles/serviceusage.serviceUsageAdmin
)

# gcloud writes progress lines ("Created service account...", "Updated IAM
# policy...") to stderr, so >/dev/null alone does not silence them. Capture
# stderr and surface it only when the call actually fails.
die() { echo "error: $*" >&2; exit 1; }

run_quiet() {
  local err
  if ! err="$("$@" 2>&1 >/dev/null)"; then
    [[ -n "$err" ]] && echo "$err" >&2
    return 1
  fi
  return 0
}

# Service account creation is eventually consistent. `describe` and
# `keys create` can both 404 for several seconds after `create` returns --
# longer when the same email was recently deleted and recreated, because the
# old identity is still cached.
wait_for_sa() {
  local attempt
  for attempt in $(seq 1 30); do
    if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# New IAM objects propagate through GCP subsystems independently, and each
# one reports its own symptom while it catches up:
#
#   does not exist / NOT_FOUND     identity not visible to this API yet
#   invalid_grant / JWT Signature  key exists but is not usable for tokens yet
#   PERMISSION_DENIED / 403        role binding not yet in effect
#
# Retry those; fail immediately on anything else so real errors are not
# buried. A genuine misconfiguration still surfaces, just after the window.
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-20}"
RETRY_SLEEP="${RETRY_SLEEP:-3}"

retry_propagation() {
  local attempt err=""
  for attempt in $(seq 1 "$RETRY_ATTEMPTS"); do
    if err="$("$@" 2>&1 >/dev/null)"; then
      return 0
    fi
    case "$err" in
      *"does not exist"*|*NOT_FOUND*|*invalid_grant*|*"Invalid JWT Signature"*|*PERMISSION_DENIED*|*"403"*)
        sleep "$RETRY_SLEEP"
        ;;
      *)
        [[ -n "$err" ]] && echo "$err" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$err" ]] && echo "$err" >&2
  return 1
}

echo "project: ${PROJECT}"
echo

# --- service account -------------------------------------------------------
echo "service account"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  echo "  ${SA_EMAIL} (exists)"
else
  run_quiet gcloud iam service-accounts create "$SA_NAME" \
    --display-name="incident-automation bootstrap" \
    --quiet
  echo "  ${SA_EMAIL} (created)"
  wait_for_sa || die "service account was created but did not become visible"
  echo "  propagated"
fi
echo

# --- roles -----------------------------------------------------------------
# add-iam-policy-binding is a read-modify-write that reports "Updated IAM
# policy" whether or not anything changed. Read the policy once and bind only
# what is missing, so the output reflects what actually happened.
echo "roles"
granted="$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format='value(bindings.role)' 2>/dev/null || true)"

for role in "${ROLES[@]}"; do
  if grep -qxF "$role" <<<"$granted"; then
    echo "  ${role} (exists)"
  else
    retry_propagation gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$role" \
      --condition=None \
      --quiet \
      || die "could not grant ${role} to ${SA_EMAIL}"
    echo "  ${role} (granted)"
  fi
done
echo

# --- key -------------------------------------------------------------------
# `keys create` is not idempotent: every call mints another credential, and
# the account caps out at ten. Reuse the existing one when it is still live.
echo "key"
reuse=0
if [[ -f "$KEY_FILE" ]]; then
  key_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("private_key_id",""))' \
    "$KEY_FILE" 2>/dev/null || true)"
  if [[ -n "$key_id" ]] && gcloud iam service-accounts keys list \
        --iam-account="$SA_EMAIL" \
        --managed-by=user \
        --format='value(name)' 2>/dev/null | grep -q "$key_id"; then
    reuse=1
  fi
fi

if [[ $reuse -eq 1 ]]; then
  echo "  ${HOST_OUTPUT_DIR}/gcp-bootstrap-key.json (existing, still valid)"
else
  umask 077
  retry_propagation gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" --quiet \
    || die "could not create a key for ${SA_EMAIL}"
  chmod 600 "$KEY_FILE"
  echo "  ${HOST_OUTPUT_DIR}/gcp-bootstrap-key.json (created)"
fi
echo

# --- record ----------------------------------------------------------------
umask 077
cat > "$ENV_FILE" <<EOF
# Written by \`gcp bootstrap\`. Not secret, but it names the key file.
GCP_PROJECT_ID=${PROJECT}
BOOTSTRAP_SA_EMAIL=${SA_EMAIL}
BOOTSTRAP_KEY_FILE=${HOST_OUTPUT_DIR}/gcp-bootstrap-key.json
BOOTSTRAP_ROLES=${ROLES[*]}
BOOTSTRAP_CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

key_count="$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" --managed-by=user \
  --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"

# --- verify ----------------------------------------------------------------
# Everything above ran as the operator. Switch to the key that was just
# written and prove it actually works, so a bad credential surfaces here
# rather than on the next command. This is the last gcloud call that runs as
# the human, so reassigning the active account is safe.
echo "verify"
retry_propagation gcloud auth activate-service-account --key-file="$KEY_FILE" --quiet \
  || die "the key was written but could not be activated"

# The role binding can lag too, so the probe gets the same treatment.
if retry_propagation gcloud storage buckets list --limit=1 --format='value(name)'; then
  echo "  key activates, storage api reachable"
else
  echo "  key activates, but the storage api is UNREACHABLE"
  exit 1
fi
echo

cat <<EOF
done

  service account   ${SA_EMAIL}
  key               ${HOST_OUTPUT_DIR}/gcp-bootstrap-key.json
  user-managed keys ${key_count}
  record            ${HOST_OUTPUT_DIR}/bootstrap.env

Next:

  podman run --rm -v "\$PWD/output:/output" incident-automation gcp status
EOF
