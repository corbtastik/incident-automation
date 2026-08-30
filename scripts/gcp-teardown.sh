#!/usr/bin/env bash
#
# gcp teardown -- remove the bootstrap service account.
#
# Runs under the operator's own identity, mirroring `bootstrap`. The bootstrap
# account could delete itself, but removing its project-level role bindings
# needs resourcemanager.projectIamAdmin, which it deliberately does not have.
#
# This is the last step, not the first: `destroy` runs as the bootstrap
# account, so removing it while a bucket still exists strands that bucket.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROJECT="${CLOUDSDK_CORE_PROJECT:?project not set}"
SA_NAME="${BOOTSTRAP_SA_NAME:-incident-automation-bootstrap}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

ROLES=(
  roles/storage.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountKeyAdmin
  roles/serviceusage.serviceUsageAdmin
)

assume_yes=0
force=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) assume_yes=1 ;;
    --force)  force=1 ;;
  esac
done

echo "project: ${PROJECT}"
echo

# Refuse to strand resources only this account can remove.
mapfile -t owned < <(list_owned_buckets)
if [[ ${#owned[@]} -gt 0 && $force -eq 0 ]]; then
  echo "still provisioned"
  printf '  gs://%s\n' "${owned[@]}"
  echo
  die "run \`gcp destroy\` first, or pass --force to remove the bootstrap account anyway"
fi

if ! gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  echo "service account"
  echo "  ${SA_EMAIL} (absent)"
  removed_any=0
else
  removed_any=1
fi

echo "about to delete"
echo "  ${SA_EMAIL} and its ${#ROLES[@]} project role bindings"
echo

if [[ $assume_yes -eq 0 ]]; then
  [[ -t 0 ]] || die "refusing to delete without confirmation -- pass --yes, or run with -it"
  read -r -p "delete? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 0; }
  echo
fi

# Bindings first. Deleting the account first leaves the policy holding
# `deleted:` members that are awkward to clean up afterwards.
echo "roles"
granted="$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format='value(bindings.role)' 2>/dev/null || true)"

for role in "${ROLES[@]}"; do
  if grep -qxF "$role" <<<"$granted"; then
    run_quiet gcloud projects remove-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$role" \
      --condition=None \
      --quiet \
      || die "could not remove ${role}"
    echo "  ${role} (removed)"
  else
    echo "  ${role} (not bound)"
  fi
done
echo

echo "service account"
if [[ $removed_any -eq 1 ]]; then
  run_quiet gcloud iam service-accounts delete "$SA_EMAIL" --quiet \
    || die "could not delete ${SA_EMAIL}"
  echo "  ${SA_EMAIL} (deleted)"
else
  echo "  ${SA_EMAIL} (absent)"
fi
echo

echo "artifacts"
for f in gcp-bootstrap-key.json bootstrap.env; do
  if [[ -f "${OUTPUT_DIR}/${f}" ]]; then
    rm -f "${OUTPUT_DIR}/${f}"
    echo "  ${f} (removed)"
  else
    echo "  ${f} (absent)"
  fi
done
echo

# APIs are deliberately left enabled. This runs in a project the operator owns
# and may share with unrelated work; turning off storage.googleapis.com on the
# way out would be destructive well beyond this demo.
echo "done -- APIs left enabled"
