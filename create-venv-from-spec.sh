#!/usr/bin/env bash
set -euo pipefail

# Builds a venv from a profile's `venv` list spec (see run-remote.sh): a
# JSON array of single-key {TYPE: CONTENT} entries, TYPE one of
# "python"/"package"/"requirements"/"script"/"package-script"/"envvar", in
# application order (a list, not an object, so the same TYPE can appear
# more than once -- e.g. several "package" entries -- without colliding on
# key uniqueness). Invoked with the venv's already hash-addressed
# destination dir, the spec JSON (as a file, so odd characters in
# script/package-script content never have to survive a shell arg), and
# the synced project root (cwd for "requirements"/"script"/"package-script"
# entries, so relative paths and project-relative commands resolve).
VENV_DIR="${1:?Usage: $0 <venv-dir> <spec-json-file> <project-root>}"
SPEC_FILE="${2:?Usage: $0 <venv-dir> <spec-json-file> <project-root>}"
PROJECT_ROOT="${3:?Usage: $0 <venv-dir> <spec-json-file> <project-root>}"

malformed=$(jq '[.[] | select((keys | length) != 1)] | length' "$SPEC_FILE")
if [[ "$malformed" -gt 0 ]]; then
    echo "ERROR: venv spec entries must each be a single-key {TYPE: CONTENT} object" >&2
    exit 1
fi

# "envvar" entries get appended to bin/activate below, then that activate
# is sourced for the very first time before any package/script step runs --
# so an "envvar" occurring after "python" (or after any real install step)
# would either be too late to affect this build at all, or be silently
# misleading about when it actually takes effect. Enforce that they're a
# prefix of the list instead of a subtler position-specific check.
seen_other=0
while IFS= read -r entry_type; do
    if [[ "$entry_type" == "envvar" ]]; then
        if [[ "$seen_other" -eq 1 ]]; then
            echo "ERROR: \"envvar\" entries must all appear before any other entry (including \"python\")" >&2
            exit 1
        fi
    else
        seen_other=1
    fi
done < <(jq -r '.[] | keys[0]' "$SPEC_FILE")

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

# Append each "envvar" entry's export to bin/activate *before* sourcing it
# for the first time, so the vars are both persistent (every future
# activation, e.g. run-remote.sh's, picks them up from the file) and
# available during this very build (every package/script/requirements/
# package-script step below runs after this source, in the same process).
while IFS= read -r kv; do
    if [[ "$kv" != *=* ]]; then
        echo "ERROR: envvar entry must be KEY=VALUE, got '$kv'" >&2
        exit 1
    fi
    printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}" >> "$VENV_DIR/bin/activate"
done < <(jq -r '.[] | select(has("envvar")) | .envvar' "$SPEC_FILE")

source "$VENV_DIR/bin/activate"

cd "$PROJECT_ROOT"

# Everything but "python" is applied in the spec's own list order --
# installs and setup scripts can be order-dependent (e.g. a script that
# assumes an earlier package is already installed), which is also why this
# venv is hashed on the spec's exact JSON rather than an order-independent
# digest.
# Each line is a compact ["type","content"] JSON array (not tab/newline
# delimited plain text) so a "script"/"package-script" entry can safely
# contain newlines, tabs, or anything else -- jq -c escapes those inside
# its one-line-per-entry array instead of letting them break the loop.
while IFS= read -r entry; do
    type="$(jq -r '.[0]' <<< "$entry")"
    content="$(jq -r '.[1]' <<< "$entry")"
    case "$type" in
        python | envvar)
            # Both already fully applied above, before the venv was even
            # created/first activated.
            ;;
        package)
            # Not just `uv pip install "$content"` -- CONTENT can be an
            # argv-style string with flags (e.g. "-e vllm-omni
            # --no-build-isolation"), which needs to reach `uv pip install`
            # as separate arguments, not one literal string it'd fail to
            # parse as a package spec. `read -ra` splits on whitespace only
            # (no globbing, unlike a bare unquoted expansion), which is
            # enough for typical flag/package tokens but -- same as a shell
            # command line -- won't honor quotes embedded in CONTENT itself.
            echo "Installing package: $content"
            read -ra pkg_args <<< "$content"
            uv pip install "${pkg_args[@]}"
            ;;
        requirements)
            echo "Installing requirements from $content"
            uv pip install -r "$content"
            ;;
        script)
            echo "Running setup script: $content"
            bash -c "$content"
            ;;
        package-script)
            # $content computes the package args itself (e.g. picking a
            # wheel URL based on the installed CUDA/torch version) rather
            # than having them hardcoded in the profile. It writes them to
            # fd 3, one per line -- not stdout -- since stdout/stderr stay
            # free for normal progress output. Swap fd 1 and fd 3 around the
            # command substitution: content's fd 3 becomes what mapfile
            # reads, and its fd 1 is redirected to our fd 2 so any of its
            # own echoed progress is still visible instead of silently
            # captured.
            echo "Running package script: $content"
            mapfile -t pkg_args < <(bash -c "$content" 3>&1 1>&2)
            if [[ "${#pkg_args[@]}" -eq 0 ]]; then
                echo "ERROR: package-script wrote no packages to fd 3" >&2
                exit 1
            fi
            echo "Installing packages from script: ${pkg_args[*]}"
            uv pip install "${pkg_args[@]}"
            ;;
        *)
            echo "ERROR: unknown venv spec type '$type'" >&2
            exit 1
            ;;
    esac
done < <(jq -c '.[] | to_entries[0] | [.key, .value]' "$SPEC_FILE")

echo "Done."
