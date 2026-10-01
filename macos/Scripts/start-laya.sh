#!/usr/bin/env bash
# Start the local Laya decision server with the checkpoints already on this machine.
#
# GhostHand talks to this server at http://127.0.0.1:8000/v1/systemone. Nothing here
# touches the network: the checkpoints are read from disk and all caches are kept
# inside the package directory.
#
# Usage: Scripts/start-laya.sh [--device cpu|mps] [--port N]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swiftpm-env.sh"

# --- locate a Python that has Laya's serve dependencies (fastapi + uvicorn) and torch ---
PY="${LAYA_PYTHON:-}"
if [ -z "$PY" ]; then
  for candidate in \
    "/Users/threaded/projects/Laya-RAG/laya-rag/.venv/bin/python" \
    "/Users/threaded/projects/Laya/laya/.venv/bin/python" \
    "$(command -v python3 || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && \
       "$candidate" -c "import fastapi, uvicorn, torch, transformers" >/dev/null 2>&1; then
      PY="$candidate"
      break
    fi
  done
fi
if [ -z "$PY" ]; then
  echo "error: no Python with Laya's serve extras (fastapi, uvicorn) and torch was found." >&2
  echo "       Set LAYA_PYTHON to one, or install laya[serve] into a venv." >&2
  exit 1
fi

# --- locate the canonical Laya checkout (package + checkpoints) ---
LAYA_HOME="${LAYA_HOME:-/Users/threaded/projects/Laya/laya}"
if [ ! -d "$LAYA_HOME/laya" ]; then
  echo "error: Laya package not found under $LAYA_HOME (set LAYA_HOME)" >&2
  exit 1
fi
export LAYA_MODELS_ROOT="${LAYA_MODELS_ROOT:-$LAYA_HOME/models}"

# --- keep every cache inside the workspace so nothing writes outside the sandbox ---
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX="$MACOS_DIR/tmp/pycache"
export HF_HOME="$MACOS_DIR/tmp/hf"
export TRANSFORMERS_CACHE="$MACOS_DIR/tmp/hf"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export TORCH_HOME="$MACOS_DIR/tmp/torch"
export XDG_CACHE_HOME="$MACOS_DIR/tmp/xdg"
export MPLCONFIGDIR="$MACOS_DIR/tmp/mpl"
mkdir -p "$PYTHONPYCACHEPREFIX" "$HF_HOME" "$TORCH_HOME" "$XDG_CACHE_HOME" "$MPLCONFIGDIR"

# Prefer the canonical checkout over any vendored copy in the interpreter's venv.
export PYTHONPATH="$LAYA_HOME${PYTHONPATH:+:$PYTHONPATH}"

# --- defaults; CLI flags below override ---
export LAYA_HOST="${LAYA_HOST:-127.0.0.1}"
export LAYA_PORT="${LAYA_PORT:-8000}"
export LAYA_DEVICE="${LAYA_DEVICE:-cpu}"
export LAYA_PRELOAD_MODELS="${LAYA_PRELOAD_MODELS:-english}"
export LAYA_THREADS="${LAYA_THREADS:-16}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) LAYA_DEVICE="$2"; shift 2 ;;
    --port) LAYA_PORT="$2"; shift 2 ;;
    --preload) LAYA_PRELOAD_MODELS="$2"; shift 2 ;;
    --host) LAYA_HOST="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
export LAYA_DEVICE LAYA_PORT LAYA_PRELOAD_MODELS LAYA_HOST

echo "==> starting Laya: python=$PY"
echo "    LAYA_HOME=$LAYA_HOME"
echo "    LAYA_MODELS_ROOT=$LAYA_MODELS_ROOT"
echo "    listening on http://$LAYA_HOST:$LAYA_PORT  (device=$LAYA_DEVICE)"
exec "$PY" "$MACOS_DIR/Scripts/laya_serve.py"
