#!/usr/bin/env bash
set -euo pipefail

# Stateless ComfyUI boot script (intended to be fetched and piped to bash)
# - Works with RunPod "runpod-slim" images where ComfyUI lives in /workspace/runpod-slim/ComfyUI
# - Uses ComfyUI venv python if present
# - Ensures comfyui-frontend-package is installed (frontend is a pip package now) :contentReference[oaicite:0]{index=0}
#
# Required env vars (only needed if you want job + storage sync):
#   SUPABASE_URL
#   SUPABASE_SERVICE_ROLE_KEY
# Optional:
#   JOB_ID
#   COMFYUI_PORT (default 8188)
#   COMFYUI_REF  (git ref, default "master")
#   SUPABASE_BUCKET_MODELS (default "models")
#   SUPABASE_BUCKET_LORAS  (default "loras")
#   SUPABASE_BUCKET_JOBS   (default "jobs")
#   SUPABASE_BUCKET_OUTPUTS(default "outputs")
#
# Job JSON format (Supabase Storage object: jobs/<JOB_ID>.json):
# {
#   "id": "job_123",
#   "models": [{"bucket":"models","path":"checkpoints/sdxl.safetensors","target":"models/checkpoints/sdxl.safetensors"}],
#   "loras":  [{"bucket":"loras","path":"talia.safetensors","target":"models/loras/talia.safetensors"}],
#   "workflow": { ... ComfyUI prompt graph ... },
#   "output_prefix": "talia_daily"
# }
echo "BOOT_START $(date -Is)"
echo "BOOT_SCRIPT_URL=${BOOT_SCRIPT_URL:-}"

log() { echo "[$(date -Is)] $*"; }

COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_REF="${COMFYUI_REF:-master}"

SUPABASE_BUCKET_MODELS="${SUPABASE_BUCKET_MODELS:-models}"
SUPABASE_BUCKET_LORAS="${SUPABASE_BUCKET_LORAS:-loras}"
SUPABASE_BUCKET_JOBS="${SUPABASE_BUCKET_JOBS:-jobs}"
SUPABASE_BUCKET_OUTPUTS="${SUPABASE_BUCKET_OUTPUTS:-outputs}"

# Locate ComfyUI directory (covers RunPod slim and other images)
if [[ -d "/workspace/runpod-slim/ComfyUI" ]]; then
  COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
elif [[ -d "/workspace/ComfyUI" ]]; then
  COMFYUI_DIR="/workspace/ComfyUI"
else
  log "ERROR: ComfyUI directory not found at /workspace/runpod-slim/ComfyUI or /workspace/ComfyUI"
  exit 1
fi

# Prefer ComfyUI venv python if it exists
if [[ -x "${COMFYUI_DIR}/.venv/bin/python" ]]; then
  PY="${COMFYUI_DIR}/.venv/bin/python"
else
  PY="python3"
fi

# Ensure basic tooling exists
need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }; }
need_cmd curl
need_cmd jq
need_cmd git

log "BOOT_START"
log "COMFYUI_DIR=$COMFYUI_DIR"
log "PY=$PY"
log "COMFYUI_PORT=$COMFYUI_PORT"
log "COMFYUI_REF=$COMFYUI_REF"

# Update ComfyUI repo (if it is a git repo)
if [[ -d "${COMFYUI_DIR}/.git" ]]; then
  log "Updating ComfyUI repo"
  git -C "$COMFYUI_DIR" fetch --all --prune
  if git -C "$COMFYUI_DIR" show-ref --verify --quiet "refs/heads/${COMFYUI_REF}"; then
    git -C "$COMFYUI_DIR" checkout -f "$COMFYUI_REF"
    git -C "$COMFYUI_DIR" pull --ff-only || true
  else
    # supports branch names like master, main, or tags/commit SHAs
    git -C "$COMFYUI_DIR" checkout -f "$COMFYUI_REF" || git -C "$COMFYUI_DIR" checkout -f "origin/$COMFYUI_REF"
  fi
else
  log "ComfyUI is not a git repo, skipping git update"
fi

# Install requirements using the same python environment ComfyUI runs with
log "Installing ComfyUI requirements"
"$PY" -m pip install -r "${COMFYUI_DIR}/requirements.txt"

# Ensure the frontend package is present and up to date
# ComfyUI frontend is shipped as a separate pip package now :contentReference[oaicite:1]{index=1}
log "Ensuring comfyui-frontend-package is installed"
"$PY" -m pip install --upgrade comfyui-frontend-package

# Start ComfyUI
log "Starting ComfyUI"
cd "$COMFYUI_DIR"
nohup "$PY" main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" > /workspace/comfyui.log 2>&1 &

# Wait for ComfyUI to be ready
log "Waiting for ComfyUI readiness"
for i in $(seq 1 240); do
  if curl -sS "http://127.0.0.1:${COMFYUI_PORT}/system_stats" >/dev/null 2>&1; then
    log "COMFY_READY"
    break
  fi
  sleep 1
done

if ! curl -sS "http://127.0.0.1:${COMFYUI_PORT}/system_stats" >/dev/null 2>&1; then
  log "ERROR: ComfyUI did not become ready. Last log lines:"
  tail -n 200 /workspace/comfyui.log || true
  exit 1
fi

# If no job requested, stop here (ComfyUI stays running)
JOB_ID="${JOB_ID:-}"
if [[ -z "$JOB_ID" ]]; then
  log "No JOB_ID provided. Boot completed."
  exit 0
fi

# Supabase helpers (Storage)
if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  log "ERROR: JOB_ID is set but SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are missing"
  exit 1
fi

SUPABASE_URL="${SUPABASE_URL%/}"
SUPABASE_STORAGE="${SUPABASE_URL}/storage/v1"

sb_create_signed_url() {
  local bucket="$1"
  local object_path="$2"
  local expires="${3:-3600}"

  curl -sS -X POST \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    "${SUPABASE_STORAGE}/object/sign/${bucket}/${object_path}" \
    -d "{\"expiresIn\": ${expires}}" \
  | jq -r '.signedURL'
}

sb_download() {
  local bucket="$1"
  local object_path="$2"
  local dest="$3"

  mkdir -p "$(dirname "$dest")"

  local signed
  signed="$(sb_create_signed_url "$bucket" "$object_path" 3600)"
  if [[ -z "$signed" || "$signed" == "null" ]]; then
    log "ERROR: failed to create signed URL for ${bucket}/${object_path}"
    exit 1
  fi

  local url="${SUPABASE_URL}${signed}"
  log "Downloading ${bucket}/${object_path} -> $dest"
  curl -L --fail -o "$dest" "$url"
}

sb_upload() {
  local bucket="$1"
  local object_path="$2"
  local file="$3"

  log "Uploading $file -> ${bucket}/${object_path}"
  curl -sS --fail -X POST \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/octet-stream" \
    -H "x-upsert: true" \
    --data-binary @"$file" \
    "${SUPABASE_STORAGE}/object/${bucket}/${object_path}" >/dev/null
}

TMP_DIR="$(mktemp -d)"
JOB_JSON="${TMP_DIR}/job.json"

log "Fetching job: ${SUPABASE_BUCKET_JOBS}/${JOB_ID}.json"
sb_download "$SUPABASE_BUCKET_JOBS" "${JOB_ID}.json" "$JOB_JSON"

# Sync models and LoRAs into ComfyUI folder structure
sync_items() {
  local key="$1"          # "models" or "loras"
  local default_bucket="$2"

  jq -c ".${key}[]? // empty" "$JOB_JSON" | while read -r item; do
    local bucket path target dest
    bucket="$(echo "$item" | jq -r '.bucket // empty')"
    path="$(echo "$item" | jq -r '.path')"
    target="$(echo "$item" | jq -r '.target')"

    if [[ -z "$bucket" ]]; then
      bucket="$default_bucket"
    fi

    dest="${COMFYUI_DIR}/${target}"
    if [[ -f "$dest" ]]; then
      log "Exists, skip: $dest"
    else
      sb_download "$bucket" "$path" "$dest"
    fi
  done
}

log "Syncing LoRAs"
sync_items "loras" "$SUPABASE_BUCKET_LORAS"

log "Syncing models"
sync_items "models" "$SUPABASE_BUCKET_MODELS"

# Run workflow via ComfyUI API
PROMPT_JSON="${TMP_DIR}/prompt.json"
jq -c '.workflow' "$JOB_JSON" > "$PROMPT_JSON"

log "Submitting prompt"
RESP="$(curl -sS --fail -X POST "http://127.0.0.1:${COMFYUI_PORT}/prompt" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $(cat "$PROMPT_JSON") }")"

PROMPT_ID="$(echo "$RESP" | jq -r '.prompt_id')"
if [[ -z "$PROMPT_ID" || "$PROMPT_ID" == "null" ]]; then
  log "ERROR: prompt submit failed: $RESP"
  exit 1
fi
log "PROMPT_SUBMITTED prompt_id=$PROMPT_ID"

# Wait for queue to drain (simple approach)
log "Waiting for prompt completion"
for i in $(seq 1 3600); do
  Q="$(curl -sS "http://127.0.0.1:${COMFYUI_PORT}/queue")"
  RUNNING="$(echo "$Q" | jq -r '.queue_running | length')"
  PENDING="$(echo "$Q" | jq -r '.queue_pending | length')"
  if [[ "$RUNNING" == "0" && "$PENDING" == "0" ]]; then
    break
  fi
  sleep 2
done

OUT_DIR="${COMFYUI_DIR}/output"
if [[ ! -d "$OUT_DIR" ]]; then
  log "ERROR: output dir not found: $OUT_DIR"
  exit 1
fi

OUTPUT_PREFIX="$(jq -r '.output_prefix // "outputs"' "$JOB_JSON")"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
REMOTE_DIR="${OUTPUT_PREFIX}/${JOB_ID}/${PROMPT_ID}_${RUN_TS}"

log "Uploading outputs to ${SUPABASE_BUCKET_OUTPUTS}/${REMOTE_DIR}"
shopt -s nullglob
for f in "${OUT_DIR}"/*; do
  base="$(basename "$f")"
  sb_upload "$SUPABASE_BUCKET_OUTPUTS" "${REMOTE_DIR}/${base}" "$f"
done

log "JOB_DONE remote=${SUPABASE_BUCKET_OUTPUTS}/${REMOTE_DIR}"
exit 0
