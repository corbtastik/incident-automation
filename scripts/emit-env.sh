#!/usr/bin/env bash
#
# env write -- compose the app configuration from what setup provisioned.
#
# This is the handoff. gcp.env and atlas.env are automation's own records;
# these two files are what the demo apps consume, and they are deliberately
# written per-app rather than as one shared file: both apps read PORT, with
# different defaults, so a single file would put one of them on the wrong
# port.
#
# Runs against whatever exists. Running only the GCP half, or only Atlas, or
# the two of them days apart, all produce a file -- with the missing values
# reported rather than silently blank.
#
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SIMULATOR_ENV="${OUTPUT_DIR}/simulator.env"
VISUALIZER_ENV="${OUTPUT_DIR}/visualizer.env"
APP_KEY_FILE="${OUTPUT_DIR}/incident-app-storage-key.json"
RUNTIME_KEY_FILE="${OUTPUT_DIR}/gcp-runtime-key.json"

stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
missing=()

get() { read_env_value "$1" "$2" 2>/dev/null || true; }

# --- gather -----------------------------------------------------------------
mongodb_uri="$(get "$ATLAS_ENV_FILE" MONGODB_URI)"
db_name="$(get "$ATLAS_ENV_FILE" DB_NAME)"
spi_name="$(get "$ATLAS_ENV_FILE" ATLAS_SPI_NAME)"
spi_uri="$(get "$ATLAS_ENV_FILE" ATLAS_SPI_URI)"
bucket="$(get "$GCP_ENV_FILE" MEDIA_GCS_BUCKET)"

[[ -n "$mongodb_uri" ]] || missing+=("MONGODB_URI -- run \`atlas infra apply\`")
[[ -n "$spi_uri" ]]     || missing+=("ATLAS_SPI_URI -- run \`atlas infra apply\`")
[[ -n "$bucket" ]]      || missing+=("MEDIA_GCS_BUCKET -- run \`gcp apply\`")

# A missing value is emitted commented out rather than as KEY=. An empty
# string is worse than an absent one: it looks configured, and libraries that
# treat the variable as a path or a URI fail obscurely on "".
kv() {
  local key="$1" value="$2"
  if [[ -n "$value" ]]; then
    printf '%s=%s\n' "$key" "$value"
  else
    printf '#%s=   # not provisioned yet\n' "$key"
  fi
}

db_name="${db_name:-incidents}"
dataset="${MEDIA_DATASET:-demo-v1}"
model_key="${ATLAS_MODEL_API_KEY:-}"
map_style="${VITE_MAP_STYLE_URL:-https://basemaps.cartocdn.com/gl/positron-gl-style/style.json}"

# The credentials line is deliberately left commented. An empty value makes
# Google's auth library try to open a file at "", which fails with something
# unhelpful; commented out, it reads as "not configured yet".
creds_block() {
  cat <<EOF
# Absolute path to the key file emitted next to this one. Copy
# incident-app-storage-key.json to wherever you keep app config, then set the
# full path here. A relative path resolves from the app's working directory,
# not from this file, so an absolute path is the safe choice.
#   GOOGLE_APPLICATION_CREDENTIALS=/absolute/path/to/incident-app-storage-key.json
#GOOGLE_APPLICATION_CREDENTIALS=
EOF
}

model_block() {
  if [[ -n "$model_key" ]]; then
    echo "ATLAS_MODEL_API_KEY=${model_key}"
  else
    cat <<'EOF'
# Supplied by you -- issued in Atlas, used for embeddings and the autoEmbed
# index. Pass ATLAS_MODEL_API_KEY to setup and it will be filled in here.
#ATLAS_MODEL_API_KEY=
EOF
  fi
}

umask 077

# --- simulator ---------------------------------------------------------------
cat > "$SIMULATOR_ENV" <<EOF
# incident-simulator configuration
# Written by incident-automation on ${stamp}
#
# Copy to the simulator's config location, along with
# incident-app-storage-key.json.

# --- Atlas (atlas infra apply) ---
$(kv MONGODB_URI "$mongodb_uri")
DB_NAME=${db_name}
COLL_NAME=incident_events

# --- Atlas Stream Processing (atlas infra apply) ---
# The simulator connects here with mongosh to create its stream processors,
# so it needs no Atlas API credentials of its own.
$(kv ATLAS_SPI_NAME "$spi_name")
$(kv ATLAS_SPI_URI "$spi_uri")

# --- GCS media (gcp apply) ---
MEDIA_ENABLED=true
MEDIA_SOURCE=gcs
$(kv MEDIA_GCS_BUCKET "$bucket")
MEDIA_DATASET=${dataset}

$(creds_block)

# --- Embeddings ---
$(model_block)

# --- Local ---
PORT=5050
ALLOWED_ORIGIN=http://localhost:5173
EOF

# --- visualizer --------------------------------------------------------------
cat > "$VISUALIZER_ENV" <<EOF
# incident-visualizer configuration
# Written by incident-automation on ${stamp}
#
# Copy to the visualizer's config location, along with
# incident-app-storage-key.json.

# --- Atlas (atlas infra apply) ---
$(kv MONGODB_URI "$mongodb_uri")
DB_NAME=${db_name}

# --- GCS media (gcp apply) ---
$(kv MEDIA_GCS_BUCKET "$bucket")
MEDIA_DATASET=${dataset}

$(creds_block)

# --- Embeddings ---
$(model_block)

# --- Map tiles ---
VITE_MAP_STYLE_URL=${map_style}
EOF

# --- key --------------------------------------------------------------------
# Copied rather than moved: gcp destroy owns gcp-runtime-key.json and deletes
# it with the identity it belongs to.
if [[ -f "$RUNTIME_KEY_FILE" ]]; then
  cp "$RUNTIME_KEY_FILE" "$APP_KEY_FILE"
  chmod 600 "$APP_KEY_FILE"
  key_state="copied from gcp-runtime-key.json"
else
  key_state="MISSING -- run \`gcp apply\`"
  missing+=("incident-app-storage-key.json -- run \`gcp apply\`")
fi

cat <<EOF
wrote

  ${HOST_OUTPUT_DIR}/simulator.env
  ${HOST_OUTPUT_DIR}/visualizer.env
  ${HOST_OUTPUT_DIR}/incident-app-storage-key.json  (${key_state})
EOF

if [[ ${#missing[@]} -gt 0 ]]; then
  echo
  echo "incomplete -- these values could not be filled in:"
  printf '  %s\n' "${missing[@]}"
  echo
  echo "the files were still written; re-run \`env write\` once the missing half is provisioned"
  exit 1
fi

cat <<EOF

Set GOOGLE_APPLICATION_CREDENTIALS in both files to the full path of
incident-app-storage-key.json once you have placed it.
EOF
