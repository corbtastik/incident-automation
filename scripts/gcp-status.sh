#!/usr/bin/env bash
#
# gcp status -- report only. Creates, modifies and deletes nothing.
#
# Phase 0: reports the authenticated identity and proves it can reach the
# Storage API in the target project. Resource reporting arrives in Phase 1.
#
set -euo pipefail

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
echo "resources"
echo "  none managed yet (phase 0)"
