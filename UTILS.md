# External command-line utilities

Enumerates the non-Python CLI tools invoked across this toolset (`run-remote.sh`,
`sync-remote.sh`, `create-venv-from-spec.sh`, the embedded remote GC script) and
the target repo's `vllm-omni-aux/utils/*.sh` scripts it runs remotely as profile
commands, along with what Python-native (stdlib or official third-party package)
replacement was considered for each and why it was or wasn't adopted.

## This toolset's own scripts

| Utility | Where | Python-native replacement considered | Verdict |
|---|---|---|---|
| `ssh` | host resolution exec, job launch, watch-loop reconnect | `paramiko`, `asyncssh`, `Fabric` | Keep external — none reliably covers `~/.ssh/config` features (`ProxyJump`, `ControlMaster`, agent forwarding) or gives PTY-passthrough streaming as cleanly as the real client |
| `scp` | shipping `create-venv-from-spec.sh` + spec JSON to remote `/tmp` | paramiko/asyncssh SFTP | Same reasoning as `ssh` — keep external for consistency |
| `rsync` | `sync-remote.sh` file sync | *(none found)* | Must stay external — no Python package replicates its delta-transfer protocol |
| `git` | `sync-remote.sh` auto-commit (`add`, `write-tree`, `commit-tree`, `update-ref`, `checkout`, push) | `pygit2` | Local plumbing could move to pygit2, but push should stay on real `git` for SSH-agent/credential-helper compatibility — net: not worth it, plumbing's already fixed and small |
| `jq` | parsing `PROFILE_JSON` throughout `run-remote.sh`; parsing the spec file in `create-venv-from-spec.sh` | stdlib `json` (plus the YAML shim already in use) | Fully replaceable, outright improvement — drops a dependency and the YAML→JSON round-trip. Note: replacing it in `create-venv-from-spec.sh` means the *remote* host needs system `python3` |
| `sha256sum` | hashing `VENV_SPEC_JSON` | `hashlib.sha256` | Fully replaceable, trivial |
| `base64` | encoding the launcher/watch/GC commands to survive ssh's flatten-and-reparse | `base64` module | Fully replaceable, trivial |
| `tee` | `exec > >(tee -a log) 2>&1` | small custom dual-writer, or `subprocess.Popen(["tee",...])` | One of the few genuinely awkward spots — no single clean idiom; still ends up shelling to `tee` or hand-rolling the duplication yourself |
| `find` / `readlink` / `grep` / `rm` | the embedded remote GC script | `pathlib`, `os.readlink`, `shutil.rmtree` | Fully replaceable — same "remote needs `python3`" caveat as `jq` above |
| `uv` | venv creation/installs in `create-venv-from-spec.sh` | *(none)* | This is the tool being orchestrated, not glue — no official Python API for its internals, stays external necessarily |

## `vllm-omni-aux/utils/*.sh` (target scripts run as profile commands)

| Utility | Where | Python-native replacement considered | Verdict |
|---|---|---|---|
| `podman build` / `podman run` | `rebuild-d3g.sh` | `podman-py` | Stays external — doesn't cover custom overlay-mount Containerfile builds |
| `podman compose` | `compose-livekit` | `podman-py` | Stays external — no compose-orchestration coverage |
| `ss -ltnp` | `poll-server-health.sh` (find ports bound by a PID) | `psutil` | Fully replaceable — fixes the one script previously flagged as awkward |
| `curl` | health-check polling (`poll-server-health.sh`), worker registration PUT (`deploy-minicpm-o-demo.sh`) | `requests` | Fully replaceable, improvement |
| `openssl req` | self-signed cert (`deploy-minicpm-o-demo.sh`) | `cryptography` | Fully replaceable |
| `hf download` | model fetch (`deploy-minicpm-o-demo.sh`) | `huggingface_hub.snapshot_download` | Fully replaceable — it's literally the library the CLI wraps |
| `pkill -f` | killing old worker/gateway procs (`deploy-minicpm-o-demo.sh`) | `psutil` | Fully replaceable |
| `hostname -I` | printing reachable IP (`deploy-minicpm-o-demo.sh`) | `socket` (UDP-connect trick to find outbound IP) | Fully replaceable, needs a small idiom rather than a one-liner |
| `nvcc --version` | CUDA tag detection (`install-flashinfer-jit-cache.sh`) | reading toolkit's `version.json`, or `pynvml` | Flagged as unreliable across CUDA versions — recommended keeping `nvcc` unless verified |
| `pytest` | `pytest.sh`, `run-pytest.sh` | — | Not a candidate — it's the actual target being run, not glue |

Everything not listed (`mkdir`, `rm -rf`, `mv`, `ln` for local-only use) was never
really "external" in the sense discussed above — those are trivial
`pathlib`/`shutil`/`os` calls already.

## Related design notes

- A "single channel" between local and remote is worth having at the *transport*
  level (SSH `ControlMaster`/`ControlPersist` multiplexing everything above over
  one connection) but not at the *protocol* level — collapsing rsync/exec/log
  streaming into one bespoke worker protocol would mean re-implementing things
  (rsync's delta transfer, reliable resumable streaming) that already work, for
  no functional gain given this tool's actual (single-job, single-client) usage.
- The reconnect watch loop currently replays the *entire* remote log on every
  reconnect (`tail -n +1 -f`) instead of resuming from where it left off. Fix is
  local: track the last byte offset already shown and reconnect with
  `tail -f -c +N` — no worker process or new protocol needed.
- No Python-over-network RPC framework (`execnet`, `mitogen`, `rpyc`, `Ray`,
  `Dask distributed`) is a real substitute for SSH here: the first two just ride
  on top of `ssh` themselves, and the rest require a persistent, separately
  authenticated listening daemon on every remote box — a worse fit than SSH for
  ephemeral spot instances that already trust your existing key.
