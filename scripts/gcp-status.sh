#!/usr/bin/env bash
#
# gcp status -- report only. Creates, modifies and deletes nothing.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
project="${CLOUDSDK_CORE_PROJECT:-}"

echo "identity"
echo "  account: ${account:-<none>}"
echo "  project: ${project:-<none>}"
echo

# Reachability probe. Deliberately a storage call rather than
# `gcloud projects describe`: roles/storage.admin does not grant
# resourcemanager.projects.get, so describe would 403 on a correctly
# scoped bootstrap account.
echo "storage api"
if probe_err="$(gcloud storage buckets list --limit=1 --format='value(name)' 2>&1 >/dev/null)"; then
  echo "  reachable"
else
  echo "  UNREACHABLE"
  echo
  echo "${probe_err}" | sed 's/^/  /'
  exit 1
fi
echo

# Prefer what a previous apply recorded; fall back to the label, so the bucket
# is still found when the output volume is missing.
echo "bucket"
bucket="$(read_env_value "$GCP_ENV_FILE" MEDIA_GCS_BUCKET 2>/dev/null || true)"
source_note="${HOST_OUTPUT_DIR}/gcp.env"
if [[ -z "$bucket" ]]; then
  mapfile -t owned < <(list_owned_buckets)
  if [[ ${#owned[@]} -eq 1 ]]; then
    bucket="${owned[0]}"
    source_note="discovered by label"
  elif [[ ${#owned[@]} -gt 1 ]]; then
    echo "  ${#owned[@]} labelled buckets found:"
    printf '    %s\n' "${owned[@]}"
    exit 0
  fi
fi

if [[ -z "$bucket" ]]; then
  echo "  none -- run \`gcp apply\`"
elif info="$(gcloud storage buckets describe "gs://${bucket}" \
      --format='csv[no-heading](location,uniform_bucket_level_access,public_access_prevention)' 2>/dev/null)"; then
  IFS=, read -r bkt_location bkt_ubla bkt_pap <<<"$info"
  echo "  gs://${bucket} (${source_note})"
  echo "  location ${bkt_location}, uniform access ${bkt_ubla}, public access ${bkt_pap}"
else
  echo "  gs://${bucket} recorded, but not found in ${project}"
  exit 1
fi

echo
echo "runtime service account"
runtime_email="$(read_env_value "$GCP_ENV_FILE" RUNTIME_SA_EMAIL 2>/dev/null || true)"
if [[ -z "$runtime_email" && -n "$bucket" ]]; then
  runtime_email="${RUNTIME_SA_NAME_BASE:-incident-app-storage}-${bucket##*-}@${project}.iam.gserviceaccount.com"
fi
if [[ -z "$runtime_email" ]]; then
  echo "  none"
elif gcloud iam service-accounts describe "$runtime_email" >/dev/null 2>&1; then
  echo "  ${runtime_email}"
  if bucket_has_binding "$bucket" "$runtime_email" "roles/storage.objectViewer"; then
    echo "  roles/storage.objectViewer on gs://${bucket}"
  else
    echo "  MISSING roles/storage.objectViewer on gs://${bucket}"
  fi
else
  echo "  ${runtime_email} (not found)"
fi
