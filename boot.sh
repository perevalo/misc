#!/usr/bin/env bash
set -euo pipefail

# Pod boot script: pull-based, no upload API
# Requirements (set as env vars on the pod/template):
#   SUPABASE_URL
#   SUPABASE_SERVICE_ROLE_KEY
# Optional:
#   JOB_ID                 (if set, process only this job; otherwise fetch next queued)
#   COMFYUI_REF            (git ref, default: master)
#   COMFYUI_PORT           (default: 8188)
#   SUPABASE_BUCKET_MODELS (default: models)
#   SUPABASE_BUCKET_LORAS  (default: loras)
#   SUPABASE_BUCKET_JOBS   (default: jobs)
#   SUPABASE_BUCKET_OUTPUTS(default: outputs)
#   COMFYUI_DIR            (default: /workspace/ComfyUI)
#   WORKFLOW_PATH          (default: /workspace/bootstrap/workflow.json)
#   OUTPUT_PREFIX          (default: generated)
#
# Job JSON expected shape (stored in Supabase Storage bucket "jobs" or in DB if you adapt):
# {
#   "id": "job_123",
#   "loras": [{"path":"talia.safetensors","target":"models/loras/talia.safetensors"}],
#   "models": [{"path":"sdxl.safetensors","target":"models/checkpoints/sdxl.safetensors"}],
#   "workflow": { ... ComfyUI API prompt graph ... },
#   "output_prefix": "talia_2025-12-26"
# }

log() { echo "[$(date -Is)] $*"; }

need_env() {
  local v="$1"
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required env var: $v" >&2
    exit 1
  fi
}

need_env SUPABASE_URL
need_env SUPABASE_SERVICE_ROLE_KEY

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_REF="${COMFYUI_REF:-master}"

SUPABASE_BUCKET_MODELS="${SUPABASE_BUCKET_MODELS:-models}"
SUPABASE_BUCKET_LORAS="${SUPABASE_BUCKET_LORAS:-loras}"
SUPABASE_BUCKET_JOBS="${SUPABASE_BUCKET_JOBS:-jobs}"
SUPABASE_BUCKET_OUTPUTS="${SUPABASE_BUCKET_OUTPUTS:-outputs}"

WORKFLOW_PATH="${WORKFLOW_PATH:-/workspace/bootstrap/workflow.json}"
OUTPUT_PREFIX_DEFAULT="${OUTPUT_PREFIX:-generated}"

BOOT_DIR="/workspace/bootstrap"
mkdir -p "$BOOT_DIR"

# Install minimal tools (best effort; container may already have them)
if command -v apt-get >/dev/null 2>&1; then
  log "Installing tools via apt-get"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl jq git python3 python3-pip ca-certificates >/dev/null
elif command -v apk >/dev/null 2>&1; then
  log "Installing tools via apk"
  apk add --no-cache curl jq git python3 py3-pip ca-certificates >/dev/null
fi

python3 -m pip install --no-cache-dir -q requests

# -------------------------
# Supabase helpers (Storage)
# -------------------------
SUPABASE_REST="${SUPABASE_URL%/}/rest/v1"
SUPABASE_STORAGE="${SUPABASE_URL%/}/storage/v1"

sb_headers() {
  cat <<EOF
Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}
apikey: ${SUPABASE_SERVICE_ROLE_KEY}
EOF
}

# Create a signed URL for a bucket object (requires service role)
# Args: bucket, object_path, expires_in_seconds
sb_create_signed_url() {
  local bucket="$1"
  local object_path="$2"
  local expires="$3"

  curl -sS -X POST \
    -H "$(sb_headers | head -n1)" \
    -H "$(sb_headers | tail -n1)" \
    -H "Content-Type: application/json" \
    "${SUPABASE_STORAGE}/object/sign/${bucket}/${object_path}" \
    -d "{\"expiresIn\": ${expires}}" \
  | jq -r '.signedURL'
}

# Download object from Storage to destination path
# Args: bucket, object_path, dest_path
sb_download() {
  local bucket="$1"
  local object_path="$2"
  local dest="$3"

  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    log "Already exists, skip download: $dest"
    return 0
  fi

  local signed
  signed="$(sb_create_signed_url "$bucket" "$object_path" 3600)"
  if [[ -z "$signed" || "$signed" == "null" ]]; then
    echo "Failed to create signed URL for ${bucket}/${object_path}" >&2
    exit 1
  fi

  local url="${SUPABASE_URL%/}${signed}"
  log "Downloading ${bucket}/${object_path} -> $dest"
  curl -L --fail -o "$dest" "$url"
}

# Upload a local file to Storage (upsert)
# Args: bucket, object_path, local_file
sb_upload() {
  local bucket="$1"
  local object_path="$2"
  local file="$3"

  log "Uploading $file -> ${bucket}/${object_path}"
  curl -sS --fail -X POST \
    -H "$(sb_headers | head -n1)" \
    -H "$(sb_headers | tail -n1)" \
    -H "Content-Type: application/octet-stream" \
    -H "x-upsert: true" \
    --data-binary @"$file" \
    "${SUPABASE_STORAGE}/object/${bucket}/${object_path}" >/dev/null
}

# -------------------------
# Ensure ComfyUI exists
# -------------------------
if [[ ! -d "$COMFYUI_DIR/.git" ]]; then
  log "Cloning ComfyUI into $COMFYUI_DIR"
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
else
  log "Updating ComfyUI"
  git -C "$COMFYUI_DIR" fetch --all --prune
fi

log "Checking out ComfyUI ref: $COMFYUI_REF"
git -C "$COMFYUI_DIR" checkout -f "$COMFYUI_REF" || git -C "$COMFYUI_DIR" checkout -f "origin/$COMFYUI_REF"

log "Installing ComfyUI requirements (best effort)"
python3 -m pip install --no-cache-dir -q -r "$COMFYUI_DIR/requirements.txt" || true

# -------------------------
# Start ComfyUI
# -------------------------
log "Starting ComfyUI on port $COMFYUI_PORT"
cd "$COMFYUI_DIR"
nohup python3 main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" > /workspace/comfyui.log 2>&1 &

# Wait for ComfyUI API to be ready
log "Waiting for ComfyUI to become ready"
for i in $(seq 1 180); do
  if curl -sS "http://127.0.0.1:${COMFYUI_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -sS "http://127.0.0.1:${COMFYUI_PORT}/" >/dev/null 2>&1; then
  echo "ComfyUI did not become ready. Check /workspace/comfyui.log" >&2
  exit 1
fi

# -------------------------
# Fetch job JSON
# -------------------------
JOB_ID="${JOB_ID:-}"

# Strategy:
# - If JOB_ID is set: read job JSON from Storage: bucket jobs, object "<JOB_ID>.json"
# - Else: require you to mount/provide a workflow json at $WORKFLOW_PATH and run once (no queue)
#
# If you want true "fetch next queued job", implement DB polling.
JOB_JSON="$BOOT_DIR/job.json"

if [[ -n "$JOB_ID" ]]; then
  log "Fetching job from Supabase Storage: ${SUPABASE_BUCKET_JOBS}/${JOB_ID}.json"
  sb_download "$SUPABASE_BUCKET_JOBS" "${JOB_ID}.json" "$JOB_JSON"
else
  if [[ ! -f "$WORKFLOW_PATH" ]]; then
    cat >&2 <<EOF
No JOB_ID provided and no WORKFLOW_PATH found.
Set JOB_ID to process a job from Supabase, or provide WORKFLOW_PATH with a ComfyUI prompt JSON.
EOF
    exit 1
  fi
  log "No JOB_ID set. Running with local workflow: $WORKFLOW_PATH"
  jq -n --arg prefix "$OUTPUT_PREFIX_DEFAULT" --slurpfile wf "$WORKFLOW_PATH" \
    '{id:"local", loras:[], models:[], workflow:$wf[0], output_prefix:$prefix}' > "$JOB_JSON"
fi

# -------------------------
# Sync models and LoRAs
# -------------------------
log "Syncing models/loras from job spec"

# Download LoRAs listed in job JSON
jq -c '.loras[]? // empty' "$JOB_JSON" | while read -r item; do
  obj="$(echo "$item" | jq -r '.path')"
  target_rel="$(echo "$item" | jq -r '.target')"
  dest="${COMFYUI_DIR}/${target_rel}"
  sb_download "$SUPABASE_BUCKET_LORAS" "$obj" "$dest"
done

# Download models listed in job JSON
jq -c '.models[]? // empty' "$JOB_JSON" | while read -r item; do
  obj="$(echo "$item" | jq -r '.path')"
  target_rel="$(echo "$item" | jq -r '.target')"
  dest="${COMFYUI_DIR}/${target_rel}"
  sb_download "$SUPABASE_BUCKET_MODELS" "$obj" "$dest"
done

# -------------------------
# Run workflow via ComfyUI API
# -------------------------
JOB_OUT_PREFIX="$(jq -r '.output_prefix // "generated"' "$JOB_JSON")"
PROMPT_JSON="$BOOT_DIR/prompt.json"

jq -c '.workflow' "$JOB_JSON" > "$PROMPT_JSON"

log "Submitting prompt to ComfyUI"
RESP="$(curl -sS --fail -X POST "http://127.0.0.1:${COMFYUI_PORT}/prompt" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $(cat "$PROMPT_JSON") }")"

PROMPT_ID="$(echo "$RESP" | jq -r '.prompt_id')"
if [[ -z "$PROMPT_ID" || "$PROMPT_ID" == "null" ]]; then
  echo "Failed to submit prompt. Response: $RESP" >&2
  exit 1
fi
log "Prompt submitted. prompt_id=$PROMPT_ID"

# Wait until queue is done for this prompt
log "Waiting for completion"
for i in $(seq 1 3600); do
  Q="$(curl -sS "http://127.0.0.1:${COMFYUI_PORT}/queue")"
  RUNNING="$(echo "$Q" | jq -r '.queue_running | length')"
  PENDING="$(echo "$Q" | jq -r '.queue_pending | length')"
  if [[ "$RUNNING" == "0" && "$PENDING" == "0" ]]; then
    break
  fi
  sleep 2
done

# -------------------------
# Upload outputs
# -------------------------
OUT_DIR="${COMFYUI_DIR}/output"
if [[ ! -d "$OUT_DIR" ]]; then
  echo "Output dir not found: $OUT_DIR" >&2
  exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"
REMOTE_DIR="${JOB_OUT_PREFIX}/${PROMPT_ID}_${RUN_TS}"

log "Uploading outputs from $OUT_DIR to ${SUPABASE_BUCKET_OUTPUTS}/${REMOTE_DIR}"
shopt -s nullglob
for f in "$OUT_DIR"/*; do
  base="$(basename "$f")"
  sb_upload "$SUPABASE_BUCKET_OUTPUTS" "${REMOTE_DIR}/${base}" "$f"
done

log "Done. Outputs uploaded to ${SUPABASE_BUCKET_OUTPUTS}/${REMOTE_DIR}"

# Exit so n8n can terminate the pod
exit 0
