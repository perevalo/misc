#!/usr/bin/env bash
# boot.sh
# Purpose:
# - Prepare runtime dirs under /workspace/runpod-slim
# - Ensure minimal OS tools exist
# - Ensure ComfyUI is running (ComfyUI template usually already runs it; this script starts it if not)
#
# Expected to be executed from: /workspace/runpod-slim/system/boot.sh
#
# Requirements:
# - LF line endings (not CRLF)
# - bash available

set -euo pipefail

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$ROOT/ComfyUI}"
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"

LOG_DIR="$ROOT/shared/logs"
PID_DIR="$ROOT/shared/pids"

mkdir -p \
  "$ROOT/sfw"/{datasets,loras,outputs,workflows,tmp} \
  "$ROOT/nsfw"/{datasets,loras,outputs,workflows,tmp} \
  "$ROOT/shared"/{checkpoints,vae,logs,pids,tmp}

# Install minimal tools (idempotent)
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip zip jq psmisc \
    >/dev/null
fi

# If the template already has ComfyUI installed, it is typically under /workspace/ComfyUI or similar.
# We try a few common locations and symlink to $COMFY_DIR if needed.
if [ ! -d "$COMFY_DIR" ]; then
  if [ -d "/workspace/ComfyUI" ]; then
    ln -sfn "/workspace/ComfyUI" "$COMFY_DIR"
  elif [ -d "$ROOT/comfyui" ]; then
    ln -sfn "$ROOT/comfyui" "$COMFY_DIR"
  fi
fi

# Ensure ComfyUI models layout can reference shared checkpoints and mode-specific loras
# Checkpoints in shared, LoRAs in ComfyUI/models/loras/{sfw,nsfw}
if [ -d "$COMFY_DIR/models" ]; then
  mkdir -p "$ROOT/shared/checkpoints"
  mkdir -p "$COMFY_DIR/models/loras"/{sfw,nsfw}

  # Optional: symlink shared checkpoints
  if [ -d "$COMFY_DIR/models/checkpoints" ]; then
    rm -rf "$COMFY_DIR/models/checkpoints"
  fi
  ln -sfn "$ROOT/shared/checkpoints" "$COMFY_DIR/models/checkpoints"

  # Symlink per-mode loras into ComfyUI selector paths
  ln -sfn "$ROOT/sfw/loras"  "$COMFY_DIR/models/loras/sfw"
  ln -sfn "$ROOT/nsfw/loras" "$COMFY_DIR/models/loras/nsfw"
fi

# Start ComfyUI only if not already listening
is_listening() {
  curl -fsS "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1
}

start_comfyui() {
  if [ ! -d "$COMFY_DIR" ]; then
    echo "ERROR: ComfyUI directory not found at $COMFY_DIR" >&2
    exit 1
  fi

  mkdir -p "$LOG_DIR" "$PID_DIR"

  echo "Starting ComfyUI on ${COMFY_HOST}:${COMFY_PORT} ..."
  nohup python3 "$COMFY_DIR/main.py" \
    --listen "$COMFY_HOST" \
    --port "$COMFY_PORT" \
    > "$LOG_DIR/comfyui.log" 2>&1 &

  echo $! > "$PID_DIR/comfyui.pid"
}

if is_listening; then
  echo "ComfyUI already running on port $COMFY_PORT"
else
  start_comfyui

  # Wait up to 90 seconds for ComfyUI to come up
  for i in $(seq 1 90); do
    if is_listening; then
      echo "ComfyUI is ready"
      break
    fi
    sleep 1
  done

  if ! is_listening; then
    echo "ERROR: ComfyUI did not become ready. Check $LOG_DIR/comfyui.log" >&2
    exit 1
  fi
fi

echo "BOOT_OK"
