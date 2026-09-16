#!/usr/bin/env bash
set -euo pipefail

# Builds a venv from a profile's `venv` list spec (see run-remote.sh): a
# JSON array of single-key {TYPE: CONTENT} entries, TYPE one of
# "python"/"package"/"requirements"/"script", in application order (a list,
# not an object, so the same TYPE can appear more than once -- e.g. several
# "package" entries -- without colliding on key uniqueness). Invoked with
# the venv's already hash-addressed destination dir, the spec JSON (as a
# file, so odd characters in script content never have to survive a shell
# arg), and the synced project root (cwd for "requirements"/"script"
# entries, so relative paths and project-relative commands resolve).
VENV_DIR="${1:?Usage: $0 <venv-dir> <spec-json-file> <project-root>}"
SPEC_FILE="${2:?Usage: $0 <venv-dir> <spec-json-file> <project-root>}"
PROJECT_ROOT="${3:?Usage: $0 <venv-dir> <spec-json-file> <project-root>}"

malformed=$(jq '[.[] | select((keys | length) != 1)] | length' "$SPEC_FILE")
if [[ "$malformed" -gt 0 ]]; then
    echo "ERROR: venv spec entries must each be a single-key {TYPE: CONTENT} object" >&2
    exit 1
fi

# cuda-toolkit's rpm doesn't add itself to PATH, and this script is normally
# invoked via `ssh host "bash create-venv-from-spec.sh"`, which runs as a
# non-interactive, non-login shell -- /etc/profile.d/cuda.sh (which does add
# it) is never sourced in that mode. Add it explicitly rather than depending
# on shell startup files that this invocation path skips.
if [[ -d /usr/local/cuda/bin ]]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

python_count=$(jq '[.[] | select(has("python"))] | length' "$SPEC_FILE")
if [[ "$python_count" -gt 1 ]]; then
    echo "ERROR: venv spec has more than one \"python\" entry" >&2
    exit 1
fi
PYTHON_VERSION="$(jq -r '[.[] | select(has("python")) | .python][0] // empty' "$SPEC_FILE")"

echo "Creating venv at $VENV_DIR (python ${PYTHON_VERSION:-default})..."
if [[ -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
fi
mkdir -p "$(dirname "$VENV_DIR")"
# Default to Python 3.14 unless the spec pins one, matching create-venv.sh.
uv venv "$VENV_DIR" --python "${PYTHON_VERSION:-3.14}"
source "$VENV_DIR/bin/activate"

cd "$PROJECT_ROOT"

# Everything but "python" is applied in the spec's own list order --
# installs and setup scripts can be order-dependent (e.g. a script that
# assumes an earlier package is already installed), which is also why this
# venv is hashed on the spec's exact JSON rather than an order-independent
# digest.
# Each line is a compact ["type","content"] JSON array (not tab/newline
# delimited plain text) so a "script" entry can safely contain newlines,
# tabs, or anything else -- jq -c escapes those inside its one-line-per-
# entry array instead of letting them break the loop.
while IFS= read -r entry; do
    type="$(jq -r '.[0]' <<< "$entry")"
    content="$(jq -r '.[1]' <<< "$entry")"
    case "$type" in
        python)
            ;;
        package)
            echo "Installing package: $content"
            uv pip install "$content"
            ;;
        requirements)
            echo "Installing requirements from $content"
            uv pip install -r "$content"
            ;;
        script)
            echo "Running setup script: $content"
            bash -c "$content"
            ;;
        *)
            echo "ERROR: unknown venv spec type '$type'" >&2
            exit 1
            ;;
    esac
done < <(jq -c '.[] | to_entries[0] | [.key, .value]' "$SPEC_FILE")

echo "Done."
