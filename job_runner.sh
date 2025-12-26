#!/usr/bin/env bash
# job_runner.sh
# Purpose:
# - Run exactly one job (MODE=sfw/nsfw with direct env vars), OR
# - Run multiple jobs from JOB_SPEC_URL (MODE=auto)
# - For each job:
#   - validate platform/mode rules
#   - download required artifacts via signed URLs (dataset zip, optional LoRA, workflow JSON)
#   - execute ComfyUI API workflow
#   - collect outputs from local output folder
#   - upload output.zip via signed PUT URL
#
# Expected env vars (single-job mode):
# - MODE=sfw|nsfw
# - JOB_ID
# - INFLUENCER_ID
# - PLATFORM=instagram|tiktok|telegram|fanvue
# - WORKFLOW_URL (signed GET to workflow JSON)
# - DATASET_ZIP_URL (optional signed GET, if you need it on pod)
# - LORA_URL (optional signed GET to .safetensors)
# - OUTPUT_ZIP_UPLOAD_URL (signed PUT to upload output.zip)
# - CALLBACK_URL (optional: n8n webhook to notify completion)
#
# Multi-job mode:
# - MODE=auto
# - JOB_SPEC_URL (signed GET to JSON: { "jobs": [ { ...job fields... }, ... ] })
#
# ComfyUI API:
# - Uses /prompt and /history endpoints on localhost:8188

set -euo pipefail

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_API="${COMFY_API:-http://127.0.0.1:${COMFY_PORT}}"

die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_cmd curl
require_cmd jq
require_cmd unzip
require_cmd zip

validate_guardrails() {
  local mode="$1"
  local platform="$2"

  # Telegram is SFW only in your design.
  if [ "$platform" = "telegram" ] && [ "$mode" != "sfw" ]; then
    die "Guardrail: telegram must be sfw"
  fi

  # Instagram/TikTok are SFW only.
  if { [ "$platform" = "instagram" ] || [ "$platform" = "tiktok" ]; } && [ "$mode" != "sfw" ]; then
    die "Guardrail: $platform must be sfw"
  fi

  # Fanvue is the only platform that may be nsfw.
  if [ "$mode" = "nsfw" ] && [ "$platform" != "fanvue" ]; then
    die "Guardrail: nsfw allowed only for fanvue"
  fi
}

download_optional() {
  local url="$1"
  local out="$2"
  if [ -n "$url" ]; then
    curl -fL "$url" -o "$out"
  fi
}

comfy_submit_prompt() {
  local workflow_json_path="$1"
  # workflow_json_path must be a full ComfyUI "prompt" JSON body (the UI workflow API format).
  # It should already include any file paths, lora names, and SaveImage node prefix.
  local resp prompt_id

  resp="$(curl -fsS -H "Content-Type: application/json" \
    -d @"$workflow_json_path" \
    "$COMFY_API/prompt")" || die "Failed to submit prompt to ComfyUI"

  prompt_id="$(echo "$resp" | jq -r '.prompt_id // empty')"
  [ -n "$prompt_id" ] || die "ComfyUI response missing prompt_id: $resp"
  echo "$prompt_id"
}

comfy_wait_done() {
  local prompt_id="$1"
  local timeout_s="${2:-1800}" # default 30 min

  local start now elapsed
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout_s" ]; then
      die "Timeout waiting for ComfyUI prompt_id=$prompt_id"
    fi

    # /history/<prompt_id> returns non-empty when finished
    if curl -fsS "$COMFY_API/history/$prompt_id" | jq -e "has(\"$prompt_id\")" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
}

run_one_job() {
  local mode="$1"
  local job_id="$2"
  local influencer_id="$3"
  local platform="$4"
  local workflow_url="$5"
  local dataset_zip_url="$6"
  local lora_url="$7"
  local output_zip_upload_url="$8"
  local callback_url="${9:-}"

  [ -n "$job_id" ] || die "JOB_ID is required"
  [ -n "$influencer_id" ] || die "INFLUENCER_ID is required"
  [ -n "$platform" ] || die "PLATFORM is required"
  [ -n "$workflow_url" ] || die "WORKFLOW_URL is required"
  [ -n "$output_zip_upload_url" ] || die "OUTPUT_ZIP_UPLOAD_URL is required"

  validate_guardrails "$mode" "$platform"

  local JOB_ROOT="$ROOT/$mode"
  local TMP="$JOB_ROOT/tmp/$job_id"
  local OUT_DIR="$JOB_ROOT/outputs/$job_id"
  local WF_PATH="$TMP/workflow.json"

  mkdir -p "$TMP" "$OUT_DIR"

  echo "Job $job_id: mode=$mode platform=$platform influencer=$influencer_id"

  # Optional dataset download/unzip (if your workflow needs local images, reference them inside workflow.json)
  if [ -n "$dataset_zip_url" ]; then
    echo "Downloading dataset.zip..."
    curl -fL "$dataset_zip_url" -o "$TMP/dataset.zip"
    mkdir -p "$JOB_ROOT/datasets/$job_id"
    unzip -o "$TMP/dataset.zip" -d "$JOB_ROOT/datasets/$job_id" >/dev/null
  fi

  # Optional LoRA download; save into mode-specific lora dir so ComfyUI can find it via symlinked paths
  if [ -n "$lora_url" ]; then
    echo "Downloading LoRA..."
    mkdir -p "$JOB_ROOT/loras"
    curl -fL "$lora_url" -o "$JOB_ROOT/loras/${influencer_id}__${mode}__latest.safetensors"
  fi

  # Download workflow JSON for this job
  echo "Downloading workflow..."
  curl -fL "$workflow_url" -o "$WF_PATH"

  # IMPORTANT:
  # Your workflow JSON should write images to a predictable place. Recommended:
  # - Set SaveImage "filename_prefix" to:
  #   sfw/outputs/<JOB_ID>/img
  #   nsfw/outputs/<JOB_ID>/img
  #
  # If your SaveImage writes into ComfyUI/output by default, you should modify workflow to use the prefix above.

  echo "Submitting prompt to ComfyUI..."
  local prompt_id
  prompt_id="$(comfy_submit_prompt "$WF_PATH")"
  echo "ComfyUI prompt_id=$prompt_id"

  echo "Waiting for completion..."
  comfy_wait_done "$prompt_id" 3600

  # Write metadata
  cat > "$OUT_DIR/meta.json" <<JSON
{
  "job_id": "$(echo "$job_id" | jq -R '.')",
  "prompt_id": "$(echo "$prompt_id" | jq -R '.')",
  "mode": "$(echo "$mode" | jq -R '.')",
  "platform": "$(echo "$platform" | jq -R '.')",
  "influencer_id": "$(echo "$influencer_id" | jq -R '.')",
  "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ" | jq -R '.')"
}
JSON

  # Package outputs
  # Expecting your workflow saved files into $OUT_DIR.
  # If not, you must copy them here before zipping.
  echo "Packaging outputs..."
  (cd "$OUT_DIR" && zip -r "$TMP/output.zip" . >/dev/null)

  echo "Uploading output.zip..."
  curl -fS -X PUT \
    -H "Content-Type: application/zip" \
    --data-binary @"$TMP/output.zip" \
    "$output_zip_upload_url" >/dev/null

  echo "Upload complete."

  if [ -n "$callback_url" ]; then
    echo "Calling callback..."
    curl -fsS -X POST \
      -H "Content-Type: application/json" \
      -d "{\"job_id\":\"$job_id\",\"mode\":\"$mode\",\"platform\":\"$platform\",\"status\":\"done\"}" \
      "$callback_url" >/dev/null || true
  fi

  echo "JOB_OK $job_id"
}

run_from_job_spec_url() {
  local job_spec_url="$1"
  [ -n "$job_spec_url" ] || die "JOB_SPEC_URL is required for MODE=auto"

  local spec tmp
  tmp="$(mktemp)"
  curl -fL "$job_spec_url" -o "$tmp"

  # Expecting: { "jobs": [ { job fields }, ... ] }
  local count
  count="$(jq '.jobs | length' "$tmp")"
  [ "$count" -ge 1 ] || die "JOB_SPEC_URL contains no jobs"

  for idx in $(seq 0 $((count - 1))); do
    local mode job_id influencer_id platform workflow_url dataset_zip_url lora_url output_zip_upload_url callback_url

    mode="$(jq -r ".jobs[$idx].mode" "$tmp")"
    job_id="$(jq -r ".jobs[$idx].job_id" "$tmp")"
    influencer_id="$(jq -r ".jobs[$idx].influencer_id" "$tmp")"
    platform="$(jq -r ".jobs[$idx].platform" "$tmp")"
    workflow_url="$(jq -r ".jobs[$idx].workflow_url" "$tmp")"
    dataset_zip_url="$(jq -r ".jobs[$idx].dataset_zip_url // empty" "$tmp")"
    lora_url="$(jq -r ".jobs[$idx].lora_url // empty" "$tmp")"
    output_zip_upload_url="$(jq -r ".jobs[$idx].output_zip_upload_url" "$tmp")"
    callback_url="$(jq -r ".jobs[$idx].callback_url // empty" "$tmp")"

    run_one_job "$mode" "$job_id" "$influencer_id" "$platform" "$workflow_url" "$dataset_zip_url" "$lora_url" "$output_zip_upload_url" "$callback_url"
  done

  rm -f "$tmp"
}

MODE="${MODE:-auto}"

if [ "$MODE" = "auto" ]; then
  run_from_job_spec_url "${JOB_SPEC_URL:-}"
else
  run_one_job \
    "$MODE" \
    "${JOB_ID:-}" \
    "${INFLUENCER_ID:-}" \
    "${PLATFORM:-}" \
    "${WORKFLOW_URL:-}" \
    "${DATASET_ZIP_URL:-}" \
    "${LORA_URL:-}" \
    "${OUTPUT_ZIP_UPLOAD_URL:-}" \
    "${CALLBACK_URL:-}"
fi

echo "ALL_DONE"
