#!/usr/bin/env bash
#
# TEMPORARY -- development helper, remove once `gcp destroy` exists.
#
# Undoes `gcp bootstrap` so phase 0 can be tested from a clean slate:
# removes the role bindings, deletes the service account, and clears the
# emitted artifacts. Runs on the host with your own gcloud, not in the
# container -- it is deliberately not part of the automation.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-corbs-cloud}"
SA_NAME="${BOOTSTRAP_SA_NAME:-incident-automation-bootstrap}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

# Resolve output/ relative to the repo root, not the caller's cwd.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${REPO_DIR}/output"

ROLES=(
  roles/storage.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountKeyAdmin
  roles/serviceusage.serviceUsageAdmin
)

assume_yes=0
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && assume_yes=1

echo "reset"
echo "  project:         ${PROJECT}"
echo "  service account: ${SA_EMAIL}"
echo "  artifacts:       ${OUTPUT_DIR}/{gcp-bootstrap-key.json,bootstrap.env}"
echo

if [[ $assume_yes -eq 0 ]]; then
  read -r -p "delete these? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 0; }
  echo
fi

# Bindings first. Deleting the account first leaves the policy holding
# `deleted:` members that are awkward to clean up afterwards.
echo "roles"
for role in "${ROLES[@]}"; do
  if gcloud projects remove-iam-policy-binding "$PROJECT" \
       --member="serviceAccount:${SA_EMAIL}" \
       --role="$role" \
       --condition=None \
       --quiet >/dev/null 2>&1; then
    echo "  ${role} (removed)"
  else
    echo "  ${role} (not bound)"
  fi
done
echo

echo "service account"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "$SA_EMAIL" --quiet >/dev/null 2>&1
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
echo "done -- ready for a fresh bootstrap"
