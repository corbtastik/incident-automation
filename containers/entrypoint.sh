#!/usr/bin/env bash
#
# incident-automation entrypoint.
#
# Dispatches on argv: <noun> <verb>, e.g. `gcp status`.
#
# Two authentication modes:
#   - service account  (status, and later verbs) -- GCP_CREDENTIALS_JSON
#   - human            (bootstrap)               -- mounted config or device-code login
#
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/incident-automation/scripts}"
MOUNTED_CONFIG="${MOUNTED_CONFIG:-/gcloud-host}"

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/common.sh"

# gcloud should never prompt or try to open a browser by default. The human
# login path re-enables prompts for that one call.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# Files to remove on exit. Populated by the auth paths.
CLEANUP_FILES=()
cleanup() {
  [[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null
  return 0
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
incident-automation

Usage:
  <noun> <verb>

Nouns and verbs:
  gcp setup       bootstrap + apply, in one command. The usual entry point.
  gcp bootstrap   Create the bootstrap service account and key. Run once.
  gcp apply       Create the media bucket and the runtime identity.
  gcp status      Report what exists. Changes nothing.
  gcp validate    Prove the runtime credential works. Changes nothing.
  gcp destroy     Delete the media bucket and runtime account. Takes --yes.
  gcp teardown    Delete the bootstrap account. Run after destroy. Takes --yes.
  help            Show this message.

Environment:
  GCP_PROJECT_ID         Required. The project to operate in.
  GCP_CREDENTIALS_JSON   Bootstrap service account key, as JSON. Required by
                         every verb except `bootstrap`, which creates it.
  BOOTSTRAP_SA_NAME      Optional. Default: incident-automation-bootstrap
  GCS_BUCKET_BASE_NAME   Required by `apply`. A random slug is appended, so
                         the bucket is <base>-<slug>. Max 56 characters.
  GCS_LOCATION           Optional. Default: us-central1
  GCP_INSTANCE_SLUG      Optional. Set to pin or re-adopt an instance.
  HOST_OUTPUT_DIR        Optional. Host path of the /output mount, recorded in
                         emitted files so paths resolve outside the container.
                         Default: ./output

Bootstrap needs an interactive terminal and a writable output volume:

  podman run --rm -it \
    -v "$PWD/output:/output" \
    -e GCP_PROJECT_ID=your-project-id \
    incident-automation gcp bootstrap

Every other verb is non-interactive. With /output mounted, the key and
project recorded by bootstrap are picked up automatically:

  podman run --rm -v "$PWD/output:/output" incident-automation gcp status

GCP_CREDENTIALS_JSON and GCP_PROJECT_ID still override, for CI where there
is no /output volume.

Not yet implemented: gcp apply | validate | destroy.
EOF
}

require_project() {
  if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
    GCP_PROJECT_ID="$(read_output_env GCP_PROJECT_ID || true)"
  fi
  [[ -n "${GCP_PROJECT_ID:-}" ]] \
    || die "GCP_PROJECT_ID is required -- set it, or mount /output from a previous bootstrap"
  export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT_ID"
}

require_output_dir() {
  [[ -d "$OUTPUT_DIR" ]] \
    || die "$OUTPUT_DIR does not exist -- mount it, e.g. -v \"\$PWD/output:$OUTPUT_DIR\""
  [[ -w "$OUTPUT_DIR" ]] \
    || die "$OUTPUT_DIR is not writable"
}

# Values written by a previous `gcp bootstrap`, so the operator does not have
# to re-supply what the tool already recorded.
read_output_env() {
  local file="${OUTPUT_DIR}/bootstrap.env" key="$1" value
  [[ -f "$file" ]] || return 1
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

active_account() {
  gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true
}

# Non-interactive. Activates the scoped bootstrap service account.
authenticate_service_account() {
  local key_file="" source=""

  if [[ -n "${GCP_CREDENTIALS_JSON:-}" ]]; then
    # Explicit argument wins. This is the path CI uses, where /output does
    # not exist.
    umask 077
    key_file="$(mktemp /tmp/gcp-bootstrap-key.XXXXXX.json)"
    CLEANUP_FILES+=("$key_file")
    printf '%s' "$GCP_CREDENTIALS_JSON" > "$key_file"
    source="GCP_CREDENTIALS_JSON"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$key_file" 2>/dev/null \
      || die "GCP_CREDENTIALS_JSON is not valid JSON"
  elif [[ -f "${OUTPUT_DIR}/gcp-bootstrap-key.json" ]]; then
    # Fall back to the key a previous bootstrap already wrote.
    key_file="${OUTPUT_DIR}/gcp-bootstrap-key.json"
    source="${OUTPUT_DIR}/gcp-bootstrap-key.json"
  elif [[ -n "$(active_account)" ]]; then
    # A pre-authenticated config was mounted.
    return 0
  else
    die "no credentials: mount /output from a previous bootstrap, set GCP_CREDENTIALS_JSON, or run \`gcp bootstrap\` first"
  fi

  local activate_err
  if ! activate_err="$(gcloud auth activate-service-account \
      --key-file="$key_file" --quiet 2>&1 >/dev/null)"; then
    [[ -n "$activate_err" ]] && echo "$activate_err" >&2
    die "could not activate the service account from ${source}"
  fi
}

# Interactive. Uses the operator's own identity, which is the only way to
# create a service account and grant it project-level roles.
authenticate_human() {
  [[ -z "${GCP_CREDENTIALS_JSON:-}" ]] || die \
    "this command runs as you, not as a service account -- unset GCP_CREDENTIALS_JSON"

  # gcloud writes logs and cache into its config directory, so a read-only
  # mount has to be copied somewhere writable before use.
  if [[ -d "$MOUNTED_CONFIG" ]]; then
    cp -a "$MOUNTED_CONFIG" /tmp/gcloud-config
    export CLOUDSDK_CONFIG=/tmp/gcloud-config
  fi

  if [[ -n "$(active_account)" ]]; then
    echo "authenticated as $(active_account)"
    return 0
  fi

  [[ -t 0 ]] || die \
    "this command needs an interactive terminal for sign-in -- add -it to podman run"

  echo "no active account; starting sign-in"
  CLOUDSDK_CORE_DISABLE_PROMPTS=0 gcloud auth login --no-launch-browser \
    || die "sign-in failed"
}

main() {
  local noun="${1:-help}"

  case "$noun" in
    help|-h|--help)
      usage
      ;;
    gcp)
      local verb="${2:-}"
      [[ -n "$verb" ]] || { usage; die "gcp: a verb is required"; }
      shift 2
      case "$verb" in
        setup)
          # Validate everything before anything is created. Otherwise a
          # missing bucket name is discovered only after the operator has
          # signed in and a service account, four roles and a key exist.
          require_project
          require_output_dir
          validate_bucket_base_name "${GCS_BUCKET_BASE_NAME:-}"
          authenticate_human
          echo
          SETUP_CHAIN=1 "$SCRIPTS_DIR/gcp-bootstrap.sh"
          echo
          SETUP_CHAIN=1 "$SCRIPTS_DIR/gcp-apply.sh"
          cat <<EOF

setup complete

Next:

  podman run --rm -v "\$PWD/output:/output" incident-automation gcp status
EOF
          ;;
        bootstrap)
          require_project
          require_output_dir
          authenticate_human
          "$SCRIPTS_DIR/gcp-bootstrap.sh" "$@"
          ;;
        apply)
          require_project
          require_output_dir
          authenticate_service_account
          "$SCRIPTS_DIR/gcp-apply.sh" "$@"
          ;;
        status)
          require_project
          authenticate_service_account
          "$SCRIPTS_DIR/gcp-status.sh" "$@"
          ;;
        validate)
          require_project
          require_output_dir
          authenticate_service_account
          "$SCRIPTS_DIR/gcp-validate.sh" "$@"
          ;;
        destroy)
          require_project
          require_output_dir
          authenticate_service_account
          "$SCRIPTS_DIR/gcp-destroy.sh" "$@"
          ;;
        teardown)
          # Runs as the operator: removing project-level bindings needs
          # permissions the bootstrap account does not hold.
          require_project
          require_output_dir
          authenticate_human
          echo
          "$SCRIPTS_DIR/gcp-teardown.sh" "$@"
          ;;
        *)
          usage
          die "gcp: unknown verb '$verb'"
          ;;
      esac
      ;;
    *)
      usage
      die "unknown command '$noun'"
      ;;
  esac
}

main "$@"
