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
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT="${CLOUDSDK_CORE_PROJECT:?project not set}"
SA_NAME="${BOOTSTRAP_SA_NAME:-incident-automation-bootstrap}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

KEY_FILE="${OUTPUT_DIR}/gcp-bootstrap-key.json"
ENV_FILE="${OUTPUT_DIR}/bootstrap.env"

ROLES=(
  roles/storage.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountKeyAdmin
  roles/serviceusage.serviceUsageAdmin
)

# `describe` can 404 for several seconds after `create` returns, longer when
# the same email was recently deleted and recreated.
wait_for_sa() {
  local attempt
  for attempt in $(seq 1 30); do
    gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}


echo "project: ${PROJECT}"
echo

# Before anything else: the storage API is needed by the verify step at the
# end, and by every later verb.
ensure_apis
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
key_state="$(ensure_sa_key "$SA_EMAIL" "$KEY_FILE")" \
  || die "could not create a key for ${SA_EMAIL}"
if [[ "$key_state" == "existing" ]]; then
  echo "  ${HOST_OUTPUT_DIR}/gcp-bootstrap-key.json (existing, still valid)"
else
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
EOF

if [[ "${SETUP_CHAIN:-0}" != "1" ]]; then
  cat <<EOF

Next:

  podman run --rm -v "\$PWD/output:/output" incident-automation gcp status
EOF
fi
