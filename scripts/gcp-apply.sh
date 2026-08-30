#!/usr/bin/env bash
#
# gcp apply -- create the media bucket and the runtime identity for it.
#
# The bucket name is <base>-<slug>. Bucket names are globally unique, so a
# fixed name would collide for the second person who ever ran this; the slug
# also doubles as an instance id, letting two demos coexist in one project.
#
# Because the name is generated, it cannot be recomputed from inputs later.
# The bucket is labelled so `status` and `destroy` can rediscover it even if
# the output volume is lost.
#
# The runtime service account is what the demo apps authenticate as. It is
# deliberately separate from the bootstrap account and holds one bucket-scoped
# role: the apps only ever read objects.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT="${CLOUDSDK_CORE_PROJECT:?project not set}"
BASE="${GCS_BUCKET_BASE_NAME:-}"
LOCATION="${GCS_LOCATION:-us-central1}"

validate_bucket_base_name "$BASE"

echo "project: ${PROJECT}"
echo

# --- resolve the instance ---------------------------------------------------
# Explicit input, then what a previous run recorded, then whatever is already
# labelled in the project, and only then a fresh one. Getting this order wrong
# means a second `apply` silently creates a second bucket.
bucket=""
slug="${GCP_INSTANCE_SLUG:-}"
origin=""

if [[ -n "$slug" ]]; then
  bucket="${BASE}-${slug}"
  origin="GCP_INSTANCE_SLUG"
elif bucket="$(read_env_value "$GCP_ENV_FILE" MEDIA_GCS_BUCKET 2>/dev/null)"; then
  slug="${bucket##*-}"
  origin="${HOST_OUTPUT_DIR}/gcp.env"
else
  mapfile -t owned < <(list_owned_buckets)
  case "${#owned[@]}" in
    0) : ;;
    1)
      bucket="${owned[0]}"
      slug="${bucket##*-}"
      origin="discovered by label"
      ;;
    *)
      printf '  %s\n' "${owned[@]}" >&2
      die "more than one labelled bucket in ${PROJECT}; set GCP_INSTANCE_SLUG to pick one"
      ;;
  esac
fi

slug_is_generated=0
if [[ -z "$bucket" ]]; then
  slug="$(generate_slug)" || die "could not generate an instance slug"
  bucket="${BASE}-${slug}"
  origin="generated"
  slug_is_generated=1
fi

echo "instance"
echo "  slug:   ${slug} (${origin})"
echo "  bucket: ${bucket}"
echo

# --- bucket -----------------------------------------------------------------
echo "bucket"
if gcloud storage buckets describe "gs://${bucket}" >/dev/null 2>&1; then
  echo "  gs://${bucket} (exists)"
else
  # Bucket names share one global namespace, so a create can lose a race with
  # a stranger. The slug exists precisely so that is recoverable: pick another
  # one and try again. Only when we generated the name, though -- silently
  # changing a name the operator pinned, or one a previous run recorded, would
  # orphan the earlier instance.
  attempt=1
  while :; do
    if err="$(gcloud storage buckets create "gs://${bucket}" \
        --location="$LOCATION" \
        --uniform-bucket-level-access \
        --public-access-prevention 2>&1 >/dev/null)"; then
      echo "  gs://${bucket} (created)"
      break
    fi

    case "$err" in
      *409*|*"already own"*|*"already exists"*|*"HTTPError 409"*)
        if [[ $slug_is_generated -eq 1 && $attempt -lt 5 ]]; then
          echo "  gs://${bucket} is taken, trying another slug"
          slug="$(generate_slug)" || die "could not generate an instance slug"
          bucket="${BASE}-${slug}"
          attempt=$((attempt + 1))
          continue
        fi
        echo "$err" >&2
        die "gs://${bucket} is taken -- choose a different GCS_BUCKET_BASE_NAME or GCP_INSTANCE_SLUG"
        ;;
      *)
        echo "$err" >&2
        die "could not create gs://${bucket}"
        ;;
    esac
  done
fi

# `buckets create` takes no --labels, so labels are applied separately. This
# is what makes the bucket rediscoverable without the output volume.
retry_propagation gcloud storage buckets update "gs://${bucket}" \
  --update-labels="${LABEL_OWNER_KEY}=${LABEL_OWNER_VALUE},instance=${slug}" \
  || die "could not label gs://${bucket}"
echo "  labelled ${LABEL_OWNER_KEY}=${LABEL_OWNER_VALUE}, instance=${slug}"
echo "  location ${LOCATION}, uniform access, public access prevented"
echo

# --- runtime identity -------------------------------------------------------
# Shares the instance slug with the bucket, so the pair stays visibly
# associated and two instances can coexist in one project.
RUNTIME_SA_NAME="${RUNTIME_SA_NAME_BASE:-incident-app-storage}-${slug}"
RUNTIME_SA_EMAIL="${RUNTIME_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
RUNTIME_KEY_FILE="${OUTPUT_DIR}/gcp-runtime-key.json"

echo "runtime service account"
if gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" >/dev/null 2>&1; then
  echo "  ${RUNTIME_SA_EMAIL} (exists)"
else
  run_quiet gcloud iam service-accounts create "$RUNTIME_SA_NAME" \
    --display-name="incident demo runtime (${slug})" --quiet \
    || die "could not create ${RUNTIME_SA_EMAIL}"
  echo "  ${RUNTIME_SA_EMAIL} (created)"
  wait_for_service_account "$RUNTIME_SA_EMAIL" \
    || die "service account was created but did not become visible"
  echo "  propagated"
fi

# Bound on the bucket, not the project: the apps get read access to this
# bucket and nothing else.
if bucket_has_binding "$bucket" "$RUNTIME_SA_EMAIL" "roles/storage.objectViewer"; then
  echo "  roles/storage.objectViewer on gs://${bucket} (exists)"
else
  retry_propagation gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
    --role="roles/storage.objectViewer" \
    || die "could not grant objectViewer on gs://${bucket}"
  echo "  roles/storage.objectViewer on gs://${bucket} (granted)"
fi

key_state="$(ensure_sa_key "$RUNTIME_SA_EMAIL" "$RUNTIME_KEY_FILE")" \
  || die "could not create a key for ${RUNTIME_SA_EMAIL}"
if [[ "$key_state" == "existing" ]]; then
  echo "  ${HOST_OUTPUT_DIR}/gcp-runtime-key.json (existing, still valid)"
else
  echo "  ${HOST_OUTPUT_DIR}/gcp-runtime-key.json (created)"
fi
echo

# --- record -----------------------------------------------------------------
umask 077
cat > "$GCP_ENV_FILE" <<EOF
# Written by \`gcp apply\`. Consumed by the demo apps.
GCP_PROJECT_ID=${PROJECT}
GCP_INSTANCE_SLUG=${slug}
GCS_LOCATION=${LOCATION}
MEDIA_GCS_BUCKET=${bucket}
GOOGLE_APPLICATION_CREDENTIALS=${HOST_OUTPUT_DIR}/gcp-runtime-key.json
RUNTIME_SA_EMAIL=${RUNTIME_SA_EMAIL}
EOF

cat <<EOF
done

  bucket    gs://${bucket}
  runtime   ${RUNTIME_SA_EMAIL}
  key       ${HOST_OUTPUT_DIR}/gcp-runtime-key.json
  record    ${HOST_OUTPUT_DIR}/gcp.env
EOF

# When chained from `setup`, the combined summary is printed there instead.
if [[ "${SETUP_CHAIN:-0}" != "1" ]]; then
  cat <<EOF

Next:

  podman run --rm -v "\$PWD/output:/output" incident-automation gcp status
EOF
fi
