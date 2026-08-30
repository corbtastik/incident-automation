#!/usr/bin/env bash
#
# gcp destroy -- remove the media bucket and its runtime identity.
#
# Deliberately narrow: it removes only what `gcp apply` created. The bootstrap
# service account is left alone, and project-level settings such as enabled
# APIs are never touched, because this runs in a project the operator owns and
# may share with unrelated work.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT="${CLOUDSDK_CORE_PROJECT:?project not set}"

assume_yes=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1

echo "project: ${PROJECT}"
echo

# Same resolution order as apply, minus generation -- destroy never invents a
# name it might then fail to find.
bucket="${GCP_INSTANCE_SLUG:+${GCS_BUCKET_BASE_NAME:-}-${GCP_INSTANCE_SLUG}}"
if [[ -z "$bucket" ]]; then
  bucket="$(read_env_value "$GCP_ENV_FILE" MEDIA_GCS_BUCKET 2>/dev/null || true)"
fi
if [[ -z "$bucket" ]]; then
  mapfile -t owned < <(list_owned_buckets)
  case "${#owned[@]}" in
    0) echo "bucket"; echo "  none found"; echo; echo "nothing to destroy"; exit 0 ;;
    1) bucket="${owned[0]}" ;;
    *)
      printf '  %s\n' "${owned[@]}" >&2
      die "more than one labelled bucket in ${PROJECT}; set GCP_INSTANCE_SLUG to pick one"
      ;;
  esac
fi

if ! gcloud storage buckets describe "gs://${bucket}" >/dev/null 2>&1; then
  echo "bucket"
  echo "  gs://${bucket} (absent)"
  rm -f "$GCP_ENV_FILE"
  echo
  echo "nothing to destroy"
  exit 0
fi

# Read this before the record is removed. Fall back to deriving it from the
# slug, so a bucket found by label can still be cleaned up fully.
runtime_email="$(read_env_value "$GCP_ENV_FILE" RUNTIME_SA_EMAIL 2>/dev/null || true)"
if [[ -z "$runtime_email" ]]; then
  slug="${bucket##*-}"
  runtime_email="${RUNTIME_SA_NAME_BASE:-incident-app-storage}-${slug}@${PROJECT}.iam.gserviceaccount.com"
fi

echo "about to delete"
echo "  gs://${bucket} and everything in it"
echo "  ${runtime_email}"
echo

if [[ $assume_yes -eq 0 ]]; then
  [[ -t 0 ]] || die "refusing to delete without confirmation -- pass --yes, or run with -it"
  read -r -p "delete? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 0; }
  echo
fi

# `buckets delete` fails while objects remain, and gcloud has no equivalent of
# Terraform's force_destroy, so remove contents and bucket together. The apps
# write objects at runtime, so this is the normal case, not an edge case.
echo "bucket"
if ! err="$(gcloud storage rm --recursive "gs://${bucket}" 2>&1 >/dev/null)"; then
  echo "$err" >&2
  die "could not delete gs://${bucket}"
fi
echo "  gs://${bucket} (deleted)"
echo

# Deleting the account also drops its bucket binding, which is already gone
# with the bucket anyway.
echo "runtime service account"
if gcloud iam service-accounts describe "$runtime_email" >/dev/null 2>&1; then
  run_quiet gcloud iam service-accounts delete "$runtime_email" --quiet \
    || die "could not delete ${runtime_email}"
  echo "  ${runtime_email} (deleted)"
else
  echo "  ${runtime_email} (absent)"
fi
echo

echo "artifacts"
for f in gcp-runtime-key.json gcp.env; do
  if [[ -f "${OUTPUT_DIR}/${f}" ]]; then
    rm -f "${OUTPUT_DIR}/${f}"
    echo "  ${f} (removed)"
  else
    echo "  ${f} (absent)"
  fi
done
echo
echo "done -- the bootstrap account is left in place"
