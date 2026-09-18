"""Hand-rolled Python wrappers for the external CLI tools run-remote's
toolchain must stay external -- see UTILS.md at the repo root for why each
one can't be replaced with a Python-native (stdlib or official third-party)
equivalent: ssh, scp, rsync, git, uv.

Every wrapper builds subprocess argv as a list, never a shell string, so
the local invocation never needs shell-quoting -- see _proc.py. The one
place quoting is still unavoidable is inside a remote command string
handed to `ssh`/`bash -c`; ssh.quote() (shlex.quote) is for that.
"""
