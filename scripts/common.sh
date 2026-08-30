#!/usr/bin/env bash
#
# Shared helpers. Sourced by each verb script.
#

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
GCP_ENV_FILE="${OUTPUT_DIR}/gcp.env"
HOST_OUTPUT_DIR="${HOST_OUTPUT_DIR:-./output}"

LABEL_OWNER_KEY="managed-by"
LABEL_OWNER_VALUE="incident-automation"

die() { echo "error: $*" >&2; exit 1; }

# Run a command, discarding its output unless it fails.
run_quiet() {
  local err
  if ! err="$("$@" 2>&1 >/dev/null)"; then
    [[ -n "$err" ]] && echo "$err" >&2
    return 1
  fi
  return 0
}

# New IAM and storage objects propagate through GCP subsystems independently,
# and each reports its own symptom while it catches up:
#
#   does not exist / NOT_FOUND     identity or bucket not visible yet
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

# Read one KEY=value out of an emitted env file.
read_env_value() {
  local file="$1" key="$2" value
  [[ -f "$file" ]] || return 1
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

# Buckets this tool owns, in the active project.
list_owned_buckets() {
  gcloud storage buckets list \
    --filter="labels.${LABEL_OWNER_KEY}=${LABEL_OWNER_VALUE}" \
    --format='value(name)' 2>/dev/null || true
}

# Bucket name rules, shared by `apply` and the `setup` preflight so a bad
# value is rejected before anything is created.
validate_bucket_base_name() {
  local base="$1"
  [[ -n "$base" ]] || die "GCS_BUCKET_BASE_NAME is required"
  # 63-char bucket limit, less a hyphen and a 6-character slug.
  [[ ${#base} -le 56 ]] \
    || die "GCS_BUCKET_BASE_NAME must be 56 characters or fewer (is ${#base})"
  [[ "$base" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || die "GCS_BUCKET_BASE_NAME must be lowercase letters, digits and hyphens, starting and ending alphanumeric"
}

# A new service account is not immediately visible to the API that created it.
wait_for_service_account() {
  local email="$1" attempt
  for attempt in $(seq 1 30); do
    gcloud iam service-accounts describe "$email" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Is this role already bound to this member on this bucket?
#
# `gcloud storage buckets get-iam-policy` accepts no --filter, so the policy
# is parsed rather than filtered server-side. Passing --filter here silently
# errors out and every check comes back false.
bucket_has_binding() {
  local bucket="$1" email="$2" role="$3"
  gcloud storage buckets get-iam-policy "gs://${bucket}" --format=json 2>/dev/null \
    | python3 -c '
import json, sys
role, member = sys.argv[1], "serviceAccount:" + sys.argv[2]
policy = json.load(sys.stdin)
sys.exit(0 if any(b.get("role") == role and member in b.get("members", [])
                  for b in policy.get("bindings", [])) else 1)
' "$role" "$email"
}

# `keys create` mints a new credential on every call and accounts cap at ten,
# so reuse the key on disk when it is still live. Echoes "created" or
# "existing" for the caller to report.
ensure_sa_key() {
  local email="$1" key_file="$2" key_id=""

  if [[ -f "$key_file" ]]; then
    key_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("private_key_id",""))' \
      "$key_file" 2>/dev/null || true)"
    if [[ -n "$key_id" ]] && gcloud iam service-accounts keys list \
          --iam-account="$email" --managed-by=user \
          --format='value(name)' 2>/dev/null | grep -q "$key_id"; then
      printf 'existing'
      return 0
    fi
  fi

  umask 077
  retry_propagation gcloud iam service-accounts keys create "$key_file" \
    --iam-account="$email" --quiet || return 1
  chmod 600 "$key_file"
  printf 'created'
}

# Six lowercase alphanumerics. Used for the bucket name and shared with the
# runtime account, so the pair stays visibly associated.
generate_slug() {
  local slug
  slug="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6 || true)"
  [[ ${#slug} -eq 6 ]] || return 1
  printf '%s' "$slug"
}

# Enabling an already-enabled API is a no-op that still reports success, so
# check first and report what actually happened.
REQUIRED_APIS=(storage.googleapis.com iam.googleapis.com)

ensure_apis() {
  local enabled api
  echo "apis"
  if [[ "${SKIP_API_ENABLE:-false}" == "true" ]]; then
    echo "  skipped (SKIP_API_ENABLE=true)"
    return 0
  fi

  enabled="$(gcloud services list --enabled --format='value(config.name)' 2>/dev/null || true)"
  for api in "${REQUIRED_APIS[@]}"; do
    if grep -qxF "$api" <<<"$enabled"; then
      echo "  ${api} (enabled)"
    else
      retry_propagation gcloud services enable "$api" --quiet \
        || die "could not enable ${api} -- enable it in the console, or set SKIP_API_ENABLE=true"
      echo "  ${api} (turned on)"
    fi
  done
}
