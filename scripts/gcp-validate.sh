#!/usr/bin/env bash
#
# gcp validate -- prove the setup actually works.
#
# Everything else reports that API calls returned success. This exercises the
# artifact the demo apps consume: it activates the *runtime* key in a scratch
# gcloud config and reads the bucket as that identity. A wrong IAM binding or
# a stale key surfaces here rather than in the app.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT="${CLOUDSDK_CORE_PROJECT:?project not set}"
RUNTIME_KEY_FILE="${OUTPUT_DIR}/gcp-runtime-key.json"

failures=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; failures=$((failures + 1)); }

echo "project: ${PROJECT}"
echo

# --- resolve ----------------------------------------------------------------
bucket="$(read_env_value "$GCP_ENV_FILE" MEDIA_GCS_BUCKET 2>/dev/null || true)"
if [[ -z "$bucket" ]]; then
  mapfile -t owned < <(list_owned_buckets)
  [[ ${#owned[@]} -eq 1 ]] || die "no bucket recorded and ${#owned[@]} labelled buckets found -- run \`gcp apply\`"
  bucket="${owned[0]}"
fi

runtime_email="$(read_env_value "$GCP_ENV_FILE" RUNTIME_SA_EMAIL 2>/dev/null || true)"
[[ -n "$runtime_email" ]] \
  || runtime_email="${RUNTIME_SA_NAME_BASE:-incident-app-storage}-${bucket##*-}@${PROJECT}.iam.gserviceaccount.com"

echo "target"
echo "  bucket:  gs://${bucket}"
echo "  runtime: ${runtime_email}"
echo

# --- bucket -----------------------------------------------------------------
echo "bucket"
if info="$(gcloud storage buckets describe "gs://${bucket}" \
    --format='csv[no-heading](location,uniform_bucket_level_access,public_access_prevention)' 2>/dev/null)"; then
  IFS=, read -r bkt_location bkt_ubla bkt_pap <<<"$info"
  ok "exists in ${PROJECT} (${bkt_location})"
  [[ "$bkt_ubla" == "True" ]] && ok "uniform bucket-level access" || bad "uniform bucket-level access is ${bkt_ubla}"
  [[ "$bkt_pap" == "enforced" ]] && ok "public access prevention enforced" || bad "public access prevention is ${bkt_pap}"
else
  bad "gs://${bucket} not found"
fi
echo

# --- runtime identity -------------------------------------------------------
echo "runtime identity"
if gcloud iam service-accounts describe "$runtime_email" >/dev/null 2>&1; then
  ok "service account exists"
else
  bad "service account not found"
fi

if bucket_has_binding "$bucket" "$runtime_email" "roles/storage.objectViewer"; then
  ok "roles/storage.objectViewer on the bucket"
else
  bad "roles/storage.objectViewer missing on the bucket"
fi
echo

# --- the credential the apps use --------------------------------------------
# Activated in a throwaway config so the caller's own authentication, which
# later checks and chained verbs still rely on, is left untouched.
echo "credential"
if [[ -f "$RUNTIME_KEY_FILE" ]]; then
  ok "key present at ${HOST_OUTPUT_DIR}/gcp-runtime-key.json"

  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT

  if retry_propagation env CLOUDSDK_CONFIG="$scratch" \
      gcloud auth activate-service-account --key-file="$RUNTIME_KEY_FILE" --quiet; then
    ok "key activates"

    # Listing needs storage.objects.list, which objectViewer grants. It works
    # on an empty bucket, so this does not depend on anything having been
    # uploaded.
    if retry_propagation env CLOUDSDK_CONFIG="$scratch" CLOUDSDK_CORE_PROJECT="$PROJECT" \
        gcloud storage ls "gs://${bucket}"; then
      ok "runtime identity can read gs://${bucket}"
    else
      bad "runtime identity cannot read gs://${bucket}"
    fi
  else
    bad "key does not activate"
  fi
else
  bad "no key at ${HOST_OUTPUT_DIR}/gcp-runtime-key.json -- run \`gcp apply\`"
fi
echo

if [[ $failures -eq 0 ]]; then
  echo "valid -- the apps can authenticate and read the bucket"
else
  echo "${failures} check(s) failed"
  exit 1
fi
