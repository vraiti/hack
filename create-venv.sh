#!/usr/bin/env bash
set -euo pipefail

# Assumes vllm-omni is already present under $HOME/vraiti (e.g. synced by
# run-remote.sh) -- this script only builds the venv and installs into
# it, it does not clone anything.
PROJECT_ROOT="$HOME/vraiti"
VLLM_OMNI_DIR="$PROJECT_ROOT/vllm-omni"

# cuda-toolkit's rpm doesn't add itself to PATH, and this script is normally
# invoked via `ssh host "bash create-venv.sh"`, which runs as a
# non-interactive, non-login shell -- /etc/profile.d/cuda.sh (which does add
# it) is never sourced in that mode. Add it explicitly rather than depending
# on shell startup files that this invocation path skips.
if [[ -d /usr/local/cuda/bin ]]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# With no args, create the venv at $HOME/vraiti/venv. With args, pass them
# straight through to `uv venv` (e.g. `create-venv.sh other-venv --python
# path/to/other/python`) -- the first non-flag argument is then the venv
# path, same as uv venv's own convention, defaulting to uv's own default
# (.venv in cwd) if only flags were given.
if [[ $# -eq 0 ]]; then
    VENV_ARGS=("$PROJECT_ROOT/venv")
    VENV_DIR="$PROJECT_ROOT/venv"
elif [[ "$1" != -* ]]; then
    VENV_ARGS=("$@")
    VENV_DIR="$1"
else
    VENV_ARGS=("$@")
    VENV_DIR="venv"
fi

# Default to Python 3.14 unless the caller already specified one.
if [[ " ${VENV_ARGS[*]} " != *" --python "* && " ${VENV_ARGS[*]} " != *" --python="* ]]; then
    VENV_ARGS+=(--python 3.14)
fi

echo "Creating venv..."
if [ -d $VENV_DIR ]; then
	rm -rf $VENV_DIR
fi
uv venv "${VENV_ARGS[@]}"
source "$VENV_DIR/bin/activate"

VLLM_VERSION=$(grep -oP 'VLLM_VERSION[= ]+v?\K[0-9]+\.[0-9]+\.[0-9]+' "$VLLM_OMNI_DIR"/docker/Dockerfile.xpu | head -1)
if [[ -z "$VLLM_VERSION" ]]; then
    echo "ERROR: could not determine VLLM_VERSION from docker/Dockerfile.xpu" >&2
    exit 1
fi

echo "Installing vllm==$VLLM_VERSION..."
uv pip install "vllm==$VLLM_VERSION"

FLASHINFER_VERSION=$(uv pip show flashinfer-python | grep -oP '^Version: \K.*')
if [[ -z "$FLASHINFER_VERSION" ]]; then
    echo "ERROR: flashinfer not found after vllm install" >&2
    exit 1
fi

CUDA_VERSION=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
CUDA_TAG="cu${CUDA_MAJOR}0"
echo "Installing flashinfer-jit-cache==$FLASHINFER_VERSION ($CUDA_TAG)..."
if ! uv pip install "flashinfer-jit-cache==$FLASHINFER_VERSION" \
    --index-url "https://flashinfer.ai/whl/${CUDA_TAG}" 2>/dev/null; then
    echo "flashinfer-jit-cache not available, skipping (may be bundled in flashinfer-python)."
fi

echo "Installing vllm-omni in dev mode..."
cd "$VLLM_OMNI_DIR"
uv pip install setuptools-scm
VLLM_OMNI_VERSION_OVERRIDE=0.0.0 uv pip install -e . --no-build-isolation

echo "Done."
echo "  vllm:       $VLLM_VERSION"
echo "  flashinfer: $FLASHINFER_VERSION"
echo "  CUDA:       $CUDA_VERSION"
